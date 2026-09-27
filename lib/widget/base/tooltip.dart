// ─────────────────────────────────────────────────────────────────────────────
//  SmartTooltip —— 可手动指定方向、带小三角、自动避让边界的 Flutter Tooltip
//
//  特性：
//   1. 手动设置 12 种显示位置：方向(up/down/left/right) × 对齐(start/center/end)
//   2. 小三角始终对准「触发组件」的中心 —— 气泡因边界被平移(shift)/翻转(flip)
//      之后，箭头坐标会反向补偿，仍然精确指向目标中心
//   3. 边界自动调整：主轴向空间不足自动翻到对侧(flip)，侧轴向溢出自动平移(shift)，
//      最后再做一次 clamp 保证气泡完整留在视口内
//   4. 桌面端：鼠标悬停显示（可配置延迟），鼠标移入气泡可保持显示(interactive)
//
//  用法：
//   SmartTooltip(
//     message: '这是一段提示',
//     direction: TooltipDirection.down,    // 期望气泡出现在目标下方
//     align: TooltipAlign.center,          // 侧轴对齐：start / center / end
//     waitDuration: Duration(milliseconds: 200),
//     child: const Text('悬停我'),
//   );
//
//   // 手动控制显隐
//   final c = SmartTooltipController();
//   SmartTooltip(controller: c, message: 'hi', child: const Text('悬停我'));
//   c.show();
//   c.hide();
//
//   // 气泡里放可点击内容（鼠标移入气泡不会消失）
//   SmartTooltip(interactive: true, richMessage: MyRichContent(), child: ...);
//
//  仅依赖 flutter/widgets.dart、flutter/rendering.dart，无第三方包。
//  定位核心是纯函数 computeTooltipPlacement()，可直接写单测。
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// 气泡相对目标组件的方向（气泡出现在目标的哪一侧）
enum TooltipDirection { up, down, left, right }

/// 气泡在侧轴（与方向垂直的那条轴）上的对齐方式
enum TooltipAlign { start, center, end }

/// 定位结果：气泡左上角在 Overlay 坐标系中的位置 + 箭头沿边的偏移量
@immutable
class TooltipPlacement {
  const TooltipPlacement({
    required this.direction,
    required this.offset,
    required this.arrowOffset,
    required this.flipped,
  });

  /// 最终生效的方向（可能与期望方向相反，即发生了翻转）
  final TooltipDirection direction;

  /// 气泡左上角坐标（Overlay 坐标系）
  final Offset offset;

  /// 箭头尖端中心，沿「箭头所在的那条边」方向、距气泡左上角的距离
  /// 水平方向(up/down) 时为 x 偏移；垂直方向(left/right) 时为 y 偏移
  final double arrowOffset;

  /// 是否发生翻转
  final bool flipped;

  @override
  String toString() =>
      'TooltipPlacement(${direction.name}, offset: $offset, arrow: $arrowOffset, flipped: $flipped)';
}

double _clamp(double v, double lo, double hi) {
  if (hi < lo) return lo;
  return v < lo ? lo : (v > hi ? hi : v);
}

TooltipDirection _opposite(TooltipDirection d) {
  switch (d) {
    case TooltipDirection.up:
      return TooltipDirection.down;
    case TooltipDirection.down:
      return TooltipDirection.up;
    case TooltipDirection.left:
      return TooltipDirection.right;
    case TooltipDirection.right:
      return TooltipDirection.left;
  }
}

/// 纯函数：核心定位算法（方便单测）
///
/// [target]   目标组件的矩形（Overlay 坐标系）
/// [bubble]   气泡尺寸（已包含箭头占用的高度/宽度）
/// [viewport] 可用视口尺寸
/// [gap]      箭头尖端到目标组件边缘的距离
///
/// 步骤：flip(主轴向空间不足则翻到对侧) → 主轴向定位 → 侧轴向按 align 定位并 shift
///      → 反算箭头偏移，使其对准目标中心（必要时 clamp 到气泡圆角安全区内）
TooltipPlacement computeTooltipPlacement({
  required Rect target,
  required Size bubble,
  required Size viewport,
  required TooltipDirection preferred,
  required TooltipAlign align,
  required double gap,
  required double arrowWidth,
  required double radius,
  required double viewportPadding,
}) {
  final double pad = viewportPadding;
  final bool vertical =
      preferred == TooltipDirection.up || preferred == TooltipDirection.down;

  // ── 1. 翻转：主轴向可用空间不足时，翻到空间更充裕的对侧 ──────────────────────
  double spaceOf(TooltipDirection d) {
    switch (d) {
      case TooltipDirection.down:
        return viewport.height - pad - target.bottom;
      case TooltipDirection.up:
        return target.top - pad;
      case TooltipDirection.right:
        return viewport.width - pad - target.right;
      case TooltipDirection.left:
        return target.left - pad;
    }
  }

  final double need = (vertical ? bubble.height : bubble.width) + gap;
  TooltipDirection dir = preferred;
  if (spaceOf(dir) < need) {
    final TooltipDirection other = _opposite(dir);
    if (spaceOf(other) > spaceOf(dir)) dir = other;
  }

  // ── 2. 主轴向定位（并 clamp 进视口）─────────────────────────────────────────
  double left = 0;
  double top = 0;
  if (vertical) {
    top = dir == TooltipDirection.down
        ? target.bottom + gap
        : target.top - gap - bubble.height;
    top = _clamp(top, pad, viewport.height - pad - bubble.height);
  } else {
    left = dir == TooltipDirection.right
        ? target.right + gap
        : target.left - gap - bubble.width;
    left = _clamp(left, pad, viewport.width - pad - bubble.width);
  }

  // ── 3. 侧轴向按 align 定位，再 shift 进视口 ─────────────────────────────────
  if (vertical) {
    switch (align) {
      case TooltipAlign.start:
        left = target.left;
        break;
      case TooltipAlign.center:
        left = target.center.dx - bubble.width / 2;
        break;
      case TooltipAlign.end:
        left = target.right - bubble.width;
        break;
    }
    left = _clamp(left, pad, viewport.width - pad - bubble.width);
  } else {
    switch (align) {
      case TooltipAlign.start:
        top = target.top;
        break;
      case TooltipAlign.center:
        top = target.center.dy - bubble.height / 2;
        break;
      case TooltipAlign.end:
        top = target.bottom - bubble.height;
        break;
    }
    top = _clamp(top, pad, viewport.height - pad - bubble.height);
  }

  // ── 4. 反算箭头偏移：让它始终落在目标中心上 ─────────────────────────────────
  // 气泡尺寸可能小于安全区（极窄/极矮的气泡），此时退化为居中，保证箭头不越界
  final double safe = radius + arrowWidth / 2 + 2.0;
  double arrowOffset;
  if (vertical) {
    final double lo = math.min(safe, bubble.width / 2);
    final double hi = math.max(bubble.width / 2, bubble.width - safe);
    arrowOffset = _clamp(target.center.dx - left, lo, hi);
  } else {
    final double lo = math.min(safe, bubble.height / 2);
    final double hi = math.max(bubble.height / 2, bubble.height - safe);
    arrowOffset = _clamp(target.center.dy - top, lo, hi);
  }

  return TooltipPlacement(
    direction: dir,
    offset: Offset(left, top),
    arrowOffset: arrowOffset,
    flipped: dir != preferred,
  );
}

/// 手动控制 Tooltip 显隐
class SmartTooltipController {
  _SmartTooltipState? _state;

  void show() => _state?._showTooltip();

  void hide() => _state?._hideTooltip();

  bool get isVisible => _state?._entry != null;

  // ignore: use_setters_to_change_properties
  void _attach(_SmartTooltipState state) => _state = state;

  void _detach() => _state = null;
}

/// 自定义 Tooltip
class SmartTooltip extends StatefulWidget {
  const SmartTooltip({
    super.key,
    this.message,
    this.richMessage,
    required this.child,
    this.controller,

    // ── 位置 ──────────────────────────────────────────────
    this.placement = TooltipDirection.down,
    this.align = TooltipAlign.center,
    this.gap = 8,
    this.viewportPadding = 8,

    // ── 触发 ──────────────────────────────────────────────
    this.waitDuration = const Duration(milliseconds: 200),
    this.exitDelay = const Duration(milliseconds: 120),
    this.showDuration,
    this.interactive = false,
    this.enableLongPress = true,
    this.hideOnTap = true,

    // ── 外观 ──────────────────────────────────────────────
    this.backgroundColor = const Color(0xFFFFFFFF),
    this.textStyle,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: 12,
      vertical: 8,
    ),
    this.radius = 6,
    this.arrowWidth = 12,
    this.arrowHeight = 7,
    this.borderColor,
    this.borderWidth = 1,
    this.elevation = 4,
    this.maxWidth = 320,

    // ── 其它 ──────────────────────────────────────────────
    this.excludeFromSemantics = false,
    this.animationDuration = const Duration(milliseconds: 130),
    this.onShow,
    this.onHide,
  }) : assert(
         message != null || richMessage != null,
         'message 和 richMessage 至少提供一个',
       );

  /// 纯文本提示内容
  final String? message;

  /// 自定义内容（与 message 二选一，优先使用）
  final Widget? richMessage;

  /// 触发组件
  final Widget child;

  final SmartTooltipController? controller;

  /// 期望方向；空间不足会自动翻转
  final TooltipDirection placement;

  /// 侧轴对齐方式
  final TooltipAlign align;

  /// 箭头尖端到目标组件边缘的距离
  final double gap;

  /// 气泡与视口边缘的安全距离
  final double viewportPadding;

  /// 鼠标悬停多久后显示
  ///
  /// 想「永不自动显示」时传一个很大的值即可（例如 Duration(days: 1)）
  final Duration waitDuration;

  /// 鼠标移出多久后隐藏（interactive 时鼠标进入气泡会取消该计时）
  final Duration? exitDelay;

  /// 显示后自动隐藏的时长；null 表示不自动隐藏
  final Duration? showDuration;

  /// 气泡是否接收鼠标事件（鼠标可移入气泡而不消失，气泡内可放链接/按钮）
  final bool interactive;

  /// 是否支持长按触发（移动端）
  final bool enableLongPress;

  /// 点击目标组件时是否立刻隐藏气泡
  ///
  /// 桌面端常见行为（多数第三方 Tooltip 也是这样）：点击后气泡挡着内容很烦。
  /// 用 [Listener] 而不是 GestureDetector，因为 child 里常常自带 InkWell/GestureDetector，
  /// 手势竞技场会先判给 child，父级的 onTap 收不到。
  final bool hideOnTap;

  final Color backgroundColor;
  final TextStyle? textStyle;
  final EdgeInsets contentPadding;
  final double radius;
  final double arrowWidth;
  final double arrowHeight;
  final Color? borderColor;
  final double borderWidth;
  final double elevation;
  final double maxWidth;

  final bool excludeFromSemantics;
  final Duration animationDuration;
  final VoidCallback? onShow;
  final VoidCallback? onHide;

  @override
  State<SmartTooltip> createState() => _SmartTooltipState();
}

class _SmartTooltipState extends State<SmartTooltip>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final GlobalKey _bubbleKey = GlobalKey(debugLabel: 'SmartTooltip bubble');
  OverlayEntry? _entry;
  TooltipPlacement? _placement;
  Timer? _showTimer;
  Timer? _hideTimer;
  ScrollPosition? _scrollPosition;
  int _measureTries = 0;

  late final AnimationController _animationController;

  @override
  void initState() {
    super.initState();
    _animationController =
        AnimationController(vsync: this, duration: widget.animationDuration)
          ..addStatusListener((AnimationStatus status) {
            if (status == AnimationStatus.dismissed) _removeEntry();
          });
    widget.controller?._attach(this);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _attachScroll();
  }

  @override
  void didUpdateWidget(covariant SmartTooltip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach();
      widget.controller?._attach(this);
    }
    if (_entry != null) {
      // 气泡挂在 Overlay 里，不会自动跟随外部变化：
      // 文案、颜色、主题切换（MaterialApp 的主题过渡动画每一帧都会重建本 widget）
      // 都必须在这里把新值推给已显示的气泡，否则颜色会停在一个过渡中间值上。
      _markEntryNeedsBuild();
    }
  }

  /// 安全刷新气泡。有两类崩溃要防：
  ///  1. entry 已被卸载（路由切换 / Overlay 重建 / 外部 remove）→ 再标脏会抛断言，
  ///     这里用 entry.mounted 拦掉，顺手清理本地引用；
  ///  2. 在 build / layout 阶段标脏 → 抛
  ///     "setState() or markNeedsBuild() called during build"
  ///     （典型场景：父树重建触发 didUpdateWidget，此时框架正在 build）。
  ///     这种一律推到本帧结束后再刷新。
  void _markEntryNeedsBuild() {
    final OverlayEntry? entry = _entry;
    if (entry == null) return;
    if (!entry.mounted) {
      _entry = null;
      _placement = null;
      return;
    }
    final SchedulerPhase phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      entry.markNeedsBuild();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final OverlayEntry? e = _entry;
      if (e == null) return;
      if (!e.mounted) {
        _entry = null;
        _placement = null;
        return;
      }
      e.markNeedsBuild();
    });
  }

  @override
  void dispose() {
    _showTimer?.cancel();
    _hideTimer?.cancel();
    _detachScroll();
    // dispose 阶段不回调 onHide，避免用户在销毁期 setState
    if (_entry?.mounted ?? false) _entry!.remove();
    _entry = null;
    _placement = null;
    _animationController.dispose();
    widget.controller?._detach();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // 窗口尺寸变化：气泡位置失效，直接隐藏（也可改为重算，隐藏更稳）
    if (_entry != null) _hideTooltip();
  }

  // ── 触发逻辑 ────────────────────────────────────────────────────────────────
  void _handleEnter() {
    _hideTimer?.cancel();
    if (_entry != null && !_entry!.mounted) {
      // entry 被外部卸载过，清掉引用，否则这里会一直认为「已显示」而不再弹出
      _entry = null;
      _placement = null;
    }
    if (_entry != null) {
      // 正在淡出时又移了回来：直接淡入，不必重建 OverlayEntry
      if (_animationController.status == AnimationStatus.reverse) {
        _animationController.forward();
      }
      return;
    }
    _showTimer?.cancel();
    if (widget.waitDuration <= Duration.zero) {
      _showTooltip();
    } else {
      _showTimer = Timer(widget.waitDuration, _showTooltip);
    }
  }

  void _handleExit() {
    _showTimer?.cancel();
    _scheduleHide();
  }

  void _handleLongPress() {
    _showTimer?.cancel();
    _hideTimer?.cancel();
    _showTooltip();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    final Duration delay = widget.exitDelay ?? Duration.zero;
    if (delay <= Duration.zero) {
      _hideTooltip();
    } else {
      _hideTimer = Timer(delay, _hideTooltip);
    }
  }

  void _showTooltip() {
    if (_entry != null || !mounted) return;
    _hideTimer?.cancel();
    _showTimer?.cancel();

    final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    _placement = null;
    _measureTries = 0;
    _entry = OverlayEntry(builder: _buildOverlay);
    overlay.insert(_entry!);
    widget.onShow?.call();

    // 第一帧 opacity 为 0，测量出真实尺寸后再定位并淡入
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureAndPlace());

    if (widget.showDuration != null) {
      _hideTimer = Timer(widget.showDuration!, _hideTooltip);
    }
  }

  void _hideTooltip() {
    _showTimer?.cancel();
    _hideTimer?.cancel();
    if (_entry == null) return;
    if (_animationController.value <= 0.0) {
      _removeEntry();
      return;
    }
    _animationController.reverse();
  }

  void _removeEntry() {
    final OverlayEntry? entry = _entry;
    if (entry == null) return;
    if (entry.mounted) entry.remove();
    _entry = null;
    _placement = null;
    widget.onHide?.call();
  }

  // ── 位置计算 ────────────────────────────────────────────────────────────────
  RenderBox? get _overlayBox {
    final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
    return overlay?.context.findRenderObject() as RenderBox?;
  }

  Rect? _targetRect() {
    final RenderObject? obj = context.findRenderObject();
    if (obj is! RenderBox || !obj.attached || !obj.hasSize) return null;
    final RenderBox? overlayBox = _overlayBox;
    if (overlayBox == null || !overlayBox.hasSize) return null;
    final Offset tl = obj.localToGlobal(Offset.zero, ancestor: overlayBox);
    return tl & obj.size;
  }

  void _attachScroll() {
    _detachScroll();
    final ScrollableState? scrollable = Scrollable.maybeOf(context);
    if (scrollable == null) return;
    _scrollPosition = scrollable.position;
    _scrollPosition?.addListener(_onScroll);
  }

  void _detachScroll() {
    _scrollPosition?.removeListener(_onScroll);
    _scrollPosition = null;
  }

  void _onScroll() {
    if (_entry == null) return;
    _updatePlacement();
  }

  void _measureAndPlace() {
    if (!mounted || _entry == null) return;
    final RenderBox? bubbleBox =
        _bubbleKey.currentContext?.findRenderObject() as RenderBox?;
    if (bubbleBox == null || !bubbleBox.hasSize) {
      if (_measureTries++ > 3) return;
      WidgetsBinding.instance.addPostFrameCallback((_) => _measureAndPlace());
      return;
    }
    _updatePlacement();
  }

  void _updatePlacement() {
    if (_entry == null) return;
    final Rect? target = _targetRect();
    final RenderBox? overlayBox = _overlayBox;
    final RenderBox? bubbleBox =
        _bubbleKey.currentContext?.findRenderObject() as RenderBox?;
    if (target == null || overlayBox == null || bubbleBox == null) return;
    if (!overlayBox.hasSize || !bubbleBox.hasSize) return;

    _placement = computeTooltipPlacement(
      target: target,
      bubble: bubbleBox.size,
      viewport: overlayBox.size,
      preferred: widget.placement,
      align: widget.align,
      gap: widget.gap,
      arrowWidth: widget.arrowWidth,
      radius: widget.radius,
      viewportPadding: widget.viewportPadding,
    );

    _markEntryNeedsBuild();
    if (_animationController.status != AnimationStatus.completed) {
      _animationController.forward();
    }
  }

  // ── Overlay 内容 ────────────────────────────────────────────────────────────
  Widget _buildOverlay(BuildContext context) {
    final TooltipPlacement? p = _placement;
    final TooltipDirection dir = p?.direction ?? widget.placement;

    Widget bubble = KeyedSubtree(
      key: _bubbleKey,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.maxWidth),
        child: _TooltipBubble(
          direction: dir,
          arrowOffset: p?.arrowOffset ?? 0,
          arrowWidth: widget.arrowWidth,
          arrowHeight: widget.arrowHeight,
          radius: widget.radius,
          color: widget.backgroundColor,
          borderColor: widget.borderColor,
          borderWidth: widget.borderWidth,
          elevation: widget.elevation,
          contentPadding: widget.contentPadding,
          child: _buildContent(),
        ),
      ),
    );

    final Animation<double> curve = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    bubble = FadeTransition(
      opacity: curve,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.92, end: 1.0).animate(curve),
        alignment: _growthAlignment(dir),
        child: bubble,
      ),
    );

    // 未定位完成的第一帧不接收事件，避免气泡瞬移时抢走 hover
    if (p == null) {
      bubble = IgnorePointer(child: bubble);
    } else if (widget.interactive) {
      bubble = MouseRegion(
        onEnter: (_) => _hideTimer?.cancel(),
        onExit: (_) => _scheduleHide(),
        child: bubble,
      );
    } else {
      bubble = IgnorePointer(child: bubble);
    }

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned(
          left: p?.offset.dx ?? 0,
          top: p?.offset.dy ?? 0,
          child: bubble,
        ),
      ],
    );
  }

  Alignment _growthAlignment(TooltipDirection dir) {
    switch (dir) {
      case TooltipDirection.down:
        return Alignment.topCenter;
      case TooltipDirection.up:
        return Alignment.bottomCenter;
      case TooltipDirection.left:
        return Alignment.centerRight;
      case TooltipDirection.right:
        return Alignment.centerLeft;
    }
  }

  Widget _buildContent() {
    final Widget? rich = widget.richMessage;
    if (rich != null) return rich;
    final TextStyle style =
        widget.textStyle ??
        const TextStyle(
          fontSize: 13,
          height: 1.45,
          color: Color(0xFF000000),
          fontWeight: FontWeight.normal,
          decoration: TextDecoration.none,
        );
    return Text(widget.message ?? '', style: style);
  }

  @override
  Widget build(BuildContext context) {
    Widget result = MouseRegion(
      onEnter: (_) => _handleEnter(),
      onExit: (_) => _handleExit(),
      child: widget.child,
    );
    if (widget.hideOnTap) {
      result = Listener(
        behavior: HitTestBehavior.deferToChild,
        onPointerUp: (_) => _hideTooltip(),
        child: result,
      );
    }
    if (widget.enableLongPress) {
      result = GestureDetector(onLongPress: _handleLongPress, child: result);
    }
    if (!widget.excludeFromSemantics && widget.message != null) {
      result = Semantics(tooltip: widget.message, child: result);
    }
    return result;
  }
}

/// 气泡：圆角矩形 + 小三角（CustomPaint 绘制，带阴影与描边）
class _TooltipBubble extends StatelessWidget {
  const _TooltipBubble({
    required this.direction,
    required this.arrowOffset,
    required this.arrowWidth,
    required this.arrowHeight,
    required this.radius,
    required this.color,
    required this.elevation,
    required this.child,
    this.borderColor,
    this.borderWidth = 1,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: 12,
      vertical: 8,
    ),
  });

  final TooltipDirection direction;
  final double arrowOffset;
  final double arrowWidth;
  final double arrowHeight;
  final double radius;
  final Color color;
  final double elevation;
  final Color? borderColor;
  final double borderWidth;
  final EdgeInsets contentPadding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final EdgeInsets arrowSpace = _arrowSpace();
    final EdgeInsets padding = EdgeInsets.only(
      left: contentPadding.left + arrowSpace.left,
      right: contentPadding.right + arrowSpace.right,
      top: contentPadding.top + arrowSpace.top,
      bottom: contentPadding.bottom + arrowSpace.bottom,
    );
    return CustomPaint(
      painter: _BubblePainter(
        direction: direction,
        arrowOffset: arrowOffset,
        arrowWidth: arrowWidth,
        arrowHeight: arrowHeight,
        radius: radius,
        color: color,
        elevation: elevation,
        borderColor: borderColor,
        borderWidth: borderWidth,
      ),
      // 箭头画在气泡外侧，需要在对应侧预留 arrowHeight 的空间
      child: Padding(padding: padding, child: child),
    );
  }

  EdgeInsets _arrowSpace() {
    switch (direction) {
      case TooltipDirection.down:
        return EdgeInsets.only(top: arrowHeight);
      case TooltipDirection.up:
        return EdgeInsets.only(bottom: arrowHeight);
      case TooltipDirection.left:
        return EdgeInsets.only(right: arrowHeight);
      case TooltipDirection.right:
        return EdgeInsets.only(left: arrowHeight);
    }
  }
}

class _BubblePainter extends CustomPainter {
  _BubblePainter({
    required this.direction,
    required this.arrowOffset,
    required this.arrowWidth,
    required this.arrowHeight,
    required this.radius,
    required this.color,
    required this.elevation,
    this.borderColor,
    this.borderWidth = 1,
  });

  final TooltipDirection direction;
  final double arrowOffset;
  final double arrowWidth;
  final double arrowHeight;
  final double radius;
  final Color color;
  final double elevation;
  final Color? borderColor;
  final double borderWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect body = _bodyRect(size);
    final Path bubble = Path()
      ..addRRect(RRect.fromRectAndRadius(body, Radius.circular(radius)));
    final Path shape = Path.combine(
      PathOperation.union,
      bubble,
      _arrowPath(body),
    );

    if (elevation > 0) {
      canvas.drawPath(
        shape.shift(Offset(0, elevation * 0.2)), // 几乎不偏移，四周都留阴影
        Paint()
          ..color =
              const Color(0x40000000) // 比原来的 0x99 淡一些
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, elevation * 1.2),
      );
    }
    canvas.drawPath(
      shape,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
    if (borderColor != null && borderWidth > 0) {
      canvas.drawPath(
        shape,
        Paint()
          ..color = borderColor!
          ..style = PaintingStyle.stroke
          ..strokeWidth = borderWidth,
      );
    }
  }

  /// 气泡主体矩形：整体尺寸减去箭头占用的那一条边
  Rect _bodyRect(Size size) {
    switch (direction) {
      case TooltipDirection.down: // 箭头在上边
        return Rect.fromLTWH(
          0,
          arrowHeight,
          size.width,
          math.max(0.0, size.height - arrowHeight),
        );
      case TooltipDirection.up: // 箭头在下边
        return Rect.fromLTWH(
          0,
          0,
          size.width,
          math.max(0.0, size.height - arrowHeight),
        );
      case TooltipDirection.right: // 箭头在左边
        return Rect.fromLTWH(
          arrowHeight,
          0,
          math.max(0.0, size.width - arrowHeight),
          size.height,
        );
      case TooltipDirection.left: // 箭头在右边
        return Rect.fromLTWH(
          0,
          0,
          math.max(0.0, size.width - arrowHeight),
          size.height,
        );
    }
  }

  /// 三角形：底边贴在气泡主体矩形的边上，尖端朝外
  Path _arrowPath(Rect body) {
    final double a = arrowOffset;
    final double half = arrowWidth / 2;
    switch (direction) {
      case TooltipDirection.down:
        return Path()
          ..moveTo(a - half, body.top)
          ..lineTo(a, body.top - arrowHeight)
          ..lineTo(a + half, body.top)
          ..close();
      case TooltipDirection.up:
        return Path()
          ..moveTo(a - half, body.bottom)
          ..lineTo(a, body.bottom + arrowHeight)
          ..lineTo(a + half, body.bottom)
          ..close();
      case TooltipDirection.right:
        return Path()
          ..moveTo(body.left, a - half)
          ..lineTo(body.left - arrowHeight, a)
          ..lineTo(body.left, a + half)
          ..close();
      case TooltipDirection.left:
        return Path()
          ..moveTo(body.right, a - half)
          ..lineTo(body.right + arrowHeight, a)
          ..lineTo(body.right, a + half)
          ..close();
    }
  }

  @override
  bool shouldRepaint(covariant _BubblePainter oldDelegate) {
    return oldDelegate.direction != direction ||
        oldDelegate.arrowOffset != arrowOffset ||
        oldDelegate.arrowWidth != arrowWidth ||
        oldDelegate.arrowHeight != arrowHeight ||
        oldDelegate.radius != radius ||
        oldDelegate.color != color ||
        oldDelegate.elevation != elevation ||
        oldDelegate.borderColor != borderColor ||
        oldDelegate.borderWidth != borderWidth;
  }
}
