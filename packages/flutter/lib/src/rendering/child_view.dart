// Copyright 2016 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:mojo_services/mojo/gfx/composition/scene_token.mojom.dart' as mojom;
import 'package:mojo_services/mojo/ui/layouts.mojom.dart' as mojom;
import 'package:mojo_services/mojo/ui/view_containers.mojom.dart' as mojom;
import 'package:mojo_services/mojo/ui/view_provider.mojom.dart' as mojom;
import 'package:mojo_services/mojo/ui/view_token.mojom.dart' as mojom;
import 'package:mojo_services/mojo/ui/views.mojom.dart' as mojom;
import 'package:mojo/application.dart';
import 'package:mojo/core.dart' as core;
import 'package:mojo/mojo/service_provider.mojom.dart' as mojom;

import 'box.dart';
import 'object.dart';

mojom.ViewProxy _initViewProxy() {
  int viewHandle = ui.MojoServices.takeView();
  if (viewHandle == core.MojoHandle.INVALID)
    return null;
  return new mojom.ViewProxy.fromHandle(new core.MojoHandle(viewHandle));
}

// TODO(abarth): The view host is a unique resource. We should structure how we
// take the handle from the engine so that multiple libraries can interact with
// the view host safely. Unfortunately, the view host has a global namespace of
// view keys, which means any scheme for sharing the view host also needs to
// provide a mechanism for coordinating about view keys.
final mojom.ViewProxy _viewProxy = _initViewProxy();
final mojom.View _view = _viewProxy?.ptr;

mojom.ViewContainer _initViewContainer() {
  mojom.ViewContainerProxy viewContainerProxy = new mojom.ViewContainerProxy.unbound();
  _view.getContainer(viewContainerProxy);
  viewContainerProxy.ptr.setListener(new mojom.ViewContainerListenerStub.unbound()..impl = _ViewContainerListenerImpl.instance);
  return viewContainerProxy.ptr;
}

final mojom.ViewContainer _viewContainer = _initViewContainer();

typedef dynamic _ResponseFactory();

class _ViewContainerListenerImpl extends mojom.ViewContainerListener {
  static final _ViewContainerListenerImpl instance = new _ViewContainerListenerImpl();

  @override
  dynamic onChildAttached(int childKey, mojom.ViewInfo childViewInfo, [_ResponseFactory responseFactory = null]) {
    ChildViewConnection connection = _connections[childKey];
    connection?._onAttachedToContainer(childViewInfo);
    return responseFactory();
  }

  @override
  dynamic onChildUnavailable(int childKey, [_ResponseFactory responseFactory = null]) {
    ChildViewConnection connection = _connections[childKey];
    connection?._onUnavailable();
    return responseFactory();
  }

  final Map<int, ChildViewConnection> _connections = new HashMap<int, ChildViewConnection>();
}

/// (mojo-only) A connection with a child view.
///
/// Used with the [ChildView] widget to display a child view.
class ChildViewConnection {
  /// Establishes a connection to the app at the given URL.
  ChildViewConnection({ String url }) {
    mojom.ViewProviderProxy viewProvider = new mojom.ViewProviderProxy.unbound();
    shell.connectToService(url, viewProvider);
    mojom.ServiceProviderProxy incomingServices = new mojom.ServiceProviderProxy.unbound();
    mojom.ServiceProviderStub outgoingServices = new mojom.ServiceProviderStub.unbound();
    _viewOwner = new mojom.ViewOwnerProxy.unbound();
    viewProvider.ptr.createView(_viewOwner, incomingServices, outgoingServices);
    viewProvider.close();
    _connection = new ApplicationConnection(outgoingServices, incomingServices);
  }

  /// Wraps an already-established connection to a child app.
  ChildViewConnection.fromViewOwner({
    mojom.ViewOwnerProxy viewOwner,
    ApplicationConnection connection
  }) : _connection = connection, _viewOwner = viewOwner;

  /// The underlying application connection to the child app.
  ///
  /// Useful for requesting services from the child app and for providing
  /// services to the child app.
  ApplicationConnection get connection => _connection;
  ApplicationConnection _connection;

  mojom.ViewOwnerProxy _viewOwner;

  static int _nextViewKey = 1;
  int _viewKey;

  VoidCallback _onViewInfoAvailable;
  mojom.ViewInfo _viewInfo;

  void _onAttachedToContainer(mojom.ViewInfo viewInfo) {
    assert(_viewInfo == null);
    _viewInfo = viewInfo;
    if (_onViewInfoAvailable != null)
      _onViewInfoAvailable();
  }

  void _onUnavailable() {
    _viewInfo = null;
  }

  void _addChildToViewHost() {
    assert(_attached);
    assert(_viewOwner != null);
    assert(_viewKey == null);
    _viewKey = _nextViewKey++;
    _viewInfo = null;
    _viewContainer?.addChild(_viewKey, _viewOwner.impl);
    _viewOwner = null;
    assert(!_ViewContainerListenerImpl.instance._connections.containsKey(_viewKey));
    _ViewContainerListenerImpl.instance._connections[_viewKey] = this;
  }

  void _removeChildFromViewHost() {
    assert(!_attached);
    assert(_viewOwner == null);
    assert(_viewKey != null);
    assert(_ViewContainerListenerImpl.instance._connections[_viewKey] == this);
    _ViewContainerListenerImpl.instance._connections.remove(_viewKey);
    _viewOwner = new mojom.ViewOwnerProxy.unbound();
    _viewContainer?.removeChild(_viewKey, _viewOwner);
    _viewKey = null;
    _viewInfo = null;
  }

  // The number of render objects attached to this view. In between frames, we
  // might have more than one connected if we get added to a new render object
  // before we get removed from the old render object. By the time we get around
  // to computing our layout, we must be back to just having one render object.
  int _attachments = 0;
  bool get _attached => _attachments > 0;

  void _attach() {
    assert(_attachments >= 0);
    ++_attachments;
    if (_viewKey == null)
      _addChildToViewHost();
  }

  void _detach() {
    assert(_attached);
    --_attachments;
    scheduleMicrotask(_removeChildFromViewHostIfNeeded);
  }

  void _removeChildFromViewHostIfNeeded() {
    assert(_attachments >= 0);
    if (_attachments == 0)
      _removeChildFromViewHost();
  }

  void _layout({ int physicalWidth, int physicalHeight, double devicePixelRatio }) {
    assert(_attached);
    assert(_attachments == 1);
    assert(_viewKey != null);
    if (_view == null)
      return;
    // TODO(abarth): Ideally we would propagate our actual constraints to be
    // able to support rich cross-app layout. For now, we give the child tight
    // constraints for simplicity.
    mojom.BoxConstraints childConstraints = new mojom.BoxConstraints()
      ..minWidth = physicalWidth
      ..maxWidth = physicalWidth
      ..minHeight = physicalHeight
      ..maxHeight = physicalHeight;
    mojom.ViewLayoutParams layoutParams = new mojom.ViewLayoutParams()
      ..constraints = childConstraints
      ..devicePixelRatio = devicePixelRatio;
    _viewContainer.layoutChild(_viewKey, layoutParams);
  }
}

/// (mojo-only) A view of a child application.
class RenderChildView extends RenderBox {
  RenderChildView({
    ChildViewConnection child,
    double scale
  }) : _scale = scale {
    this.child = child;
  }

  /// The child to display.
  ChildViewConnection get child => _child;
  ChildViewConnection _child;
  void set child (ChildViewConnection value) {
    if (value == _child)
      return;
    if (attached && _child != null) {
      _child._detach();
      assert(_child._onViewInfoAvailable != null);
      _child._onViewInfoAvailable = null;
    }
    _child = value;
    if (attached && _child != null) {
      _child._attach();
      assert(_child._onViewInfoAvailable == null);
      _child._onViewInfoAvailable = markNeedsPaint;
    }
    if (_child == null) {
      markNeedsPaint();
    } else {
      markNeedsLayout();
    }
  }

  /// The device pixel ratio to provide the child.
  double get scale => _scale;
  double _scale;
  void set scale (double value) {
    if (value == _scale)
      return;
    _scale = value;
    if (_child != null)
      markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _child?._attach();
  }

  @override
  void detach() {
    _child?._detach();
    super.detach();
  }

  @override
  bool get alwaysNeedsCompositing => true;

  TextPainter _debugErrorMessage;

  int _physicalWidth;
  int _physicalHeight;

  @override
  void performLayout() {
    size = constraints.biggest;
    if (_child != null) {
      _physicalWidth = (size.width * scale).round();
      _physicalHeight = (size.height * scale).round();
      _child._layout(physicalWidth: _physicalWidth, physicalHeight: _physicalHeight, devicePixelRatio: scale);
      assert(() {
        if (_view == null) {
          _debugErrorMessage ??= new TextPainter()
            ..text = new TextSpan(text: 'Child view are supported only when running in Mojo shell.');
          _debugErrorMessage
            ..minWidth = size.width
            ..maxWidth = size.width
            ..minHeight = size.height
            ..maxHeight = size.height
            ..layout();
        }
        return true;
      });
    }
  }

  @override
  bool hitTestSelf(Point position) => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    assert(needsCompositing);
    if (_child?._viewInfo != null)
      context.pushChildScene(offset, scale, _physicalWidth, _physicalHeight, _child._viewInfo.sceneToken);
    assert(() {
      if (_view == null) {
        context.canvas.drawRect(offset & size, new Paint()..color = const Color(0xFF0000FF));
        _debugErrorMessage.paint(context.canvas, offset);
      }
      return true;
    });
  }

  @override
  void debugFillDescription(List<String> description) {
    super.debugFillDescription(description);
    description.add('child: $child');
    description.add('scale: $scale');
  }
}
