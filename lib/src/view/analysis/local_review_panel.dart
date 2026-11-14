
import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter/material.dart' as material;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lichess_mobile/src/model/analysis/analysis_controller.dart';
import 'package:lichess_mobile/src/model/common/chess.dart';
import 'package:lichess_mobile/src/model/common/eval.dart';
import 'package:lichess_mobile/src/model/common/id.dart';
import 'package:lichess_mobile/src/model/common/node.dart';
import 'package:lichess_mobile/src/model/common/uci.dart';
import 'package:lichess_mobile/src/model/engine/evaluation_context.dart';
import 'package:lichess_mobile/src/model/engine/evaluation_preferences.dart';
import 'package:lichess_mobile/src/model/engine/position_evaluator.dart';
import 'package:lichess_mobile/src/model/engine/practice_comment.dart';
import 'package:lichess_mobile/src/model/engine/work.dart';
import 'package:lichess_mobile/src/view/offline_computer/offline_computer_game_screen.dart';
import 'package:material_ui/material_ui.dart' hide Step;

/// Only use this outside ongoing online games.
typedef LocalReviewMark = ({String symbol, Color color});

final localReviewMarksProvider = NotifierProvider.autoDispose
    .family<LocalReviewMarksController, Map<UciPath, LocalReviewMark>, String>(
      LocalReviewMarksController.new,
      name: 'LocalReviewMarksProvider',
    );

class LocalReviewMarksController(final String contextId)
    extends Notifier<Map<UciPath, LocalReviewMark>> {
  @override
  Map<UciPath, LocalReviewMark> build() => {};

  void replace(Map<UciPath, LocalReviewMark> values) => state = Map.unmodifiable(values);

  void clear() => state = {};
}

enum _ReviewMode {
  fast('Szybka', 'Krótsza analiza', Duration(seconds: 1), 10),
  detailed('Szczegółowa', 'Głębsza analiza', Duration(seconds: 4), 17);

  const _ReviewMode(this.title, this.description, this.thinkTime, this.minDepth);
  final String title;
  final String description;
  final Duration thinkTime;
  final int minDepth;
}

enum _Grade {
  brilliant('Genialny*', '!!', Color(0xFF25C7DD)),
  best('Najlepszy', '★', Color(0xFF66C79A)),
  excellent('Świetny', '!', Color(0xFF48B8DB)),
  good('Dobry', '✓', Color(0xFF9BCB77)),
  inaccuracy('Niedokładność', '?!', Color(0xFFE5B65B)),
  mistake('Błąd', '?', Color(0xFFEA965B)),
  blunder('Przeoczenie', '??', Color(0xFFE76880));

  const _Grade(this.label, this.symbol, this.color);
  final String label;
  final String symbol;
  final Color color;

  bool get isError =>
      this == inaccuracy || this == mistake || this == blunder;
}

typedef _ReviewedMove = ({
  UciPath path,
  String moveText,
  String beforeFen,
  String? bestMove,
  String score,
  Side side,
  double advantage,
  _Grade grade,
});

class const LocalReviewPanel({
  required final AnalysisOptions options,
  required final ViewRoot root,
  required final Variant variant,
  required final UciPath currentPath,
  required final void Function(UciPath) onJump,
  super.key,
}) extends ConsumerStatefulWidget {
  @override
  ConsumerState<LocalReviewPanel> createState() => _LocalReviewPanelState();
}

class _LocalReviewPanelState extends ConsumerState<LocalReviewPanel> {
  final List<_ReviewedMove> _moves = [];
  _ReviewMode _mode = _ReviewMode.fast;
  bool _running = false;
  bool _finished = false;
  int _completed = 0;
  int _total = 0;
  int _generation = 0;
  String? _message;
  StreamSubscription<EvalResult>? _activeSubscription;
  Completer<ClientEval?>? _waiting;

  EvaluationContext get _context => EvaluationContext(
    id: StringId('deep-violet-review-${widget.options.contextId.value}'),
    variant: widget.variant,
    initialPosition: widget.root.position,
  );

  @override
  void didUpdateWidget(covariant LocalReviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldLine = oldWidget.root.mainline.map((m) => m.sanMove.san).join(' ');
    final newLine = widget.root.mainline.map((m) => m.sanMove.san).join(' ');
    if (oldWidget.root.position.fen != widget.root.position.fen || oldLine != newLine) {
      _generation++;
      _activeSubscription?.cancel();
      if (_waiting case final waiting? when !waiting.isCompleted) {
        waiting.complete(null);
      }
      _moves.clear();
      _running = false;
      _finished = false;
      _completed = 0;
      _total = 0;
      _message = null;
      ref.read(localReviewMarksProvider(widget.options.contextId.value).notifier).clear();
    }
  }

  @override
  void dispose() {
    _generation++;
    _activeSubscription?.cancel();
    if (_waiting case final waiting? when !waiting.isCompleted) {
      waiting.complete(null);
    }
    super.dispose();
  }

  void _stop() {
    _generation++;
    _activeSubscription?.cancel();
    if (_waiting case final waiting? when !waiting.isCompleted) {
      waiting.complete(null);
    }
    ref.read(positionEvaluatorProvider(_context).notifier).stop();
    if (mounted) setState(() {
      _running = false;
      _message = 'Analiza przerwana. Wyniki są niepełne.';
    });
  }

  Future<ClientEval?> _evaluate(
    List<Step> steps,
    int generation, {
    required bool firstPosition,
  }) async {
    if (!mounted || generation != _generation) return null;
    final prefs = ref.read(engineEvaluationPreferencesProvider);
    final work = EvalWork(
      id: _context.id,
      variant: widget.variant,
      threads: prefs.numEngineCores,
      searchTime: _mode.thinkTime,
      multiPv: 1,
      threatMode: false,
      initialPosition: widget.root.position,
      steps: IList(steps),
    );

    ClientEval? latest;
    final waiter = Completer<ClientEval?>();
    _waiting = waiter;
    final subscription = ref
        .read(positionEvaluatorProvider(_context).notifier)
        .evaluate(work)
        .listen(
          (event) {
            if (generation != _generation) return;
            latest = event.$2;
            if (event.$2.depth >= _mode.minDepth && !waiter.isCompleted) {
              waiter.complete(event.$2);
            }
          },
          onError: (Object error) {
            if (!waiter.isCompleted) waiter.completeError(error);
          },
        );
    _activeSubscription = subscription;
    try {
      return await waiter.future.timeout(
        firstPosition ? const Duration(seconds: 18) : const Duration(seconds: 9),
        onTimeout: () => latest,
      );
    } finally {
      await subscription.cancel();
      if (identical(_activeSubscription, subscription)) _activeSubscription = null;
      if (identical(_waiting, waiter)) _waiting = null;
    }
  }

  /// Score is white-centric. Saturation prevents very large cp values
  /// from making the chart unreadable. Mate scores are drawn at its edge.
  double _advantage(ClientEval eval) {
    if (eval.mate case final mate?) return mate > 0 ? 1.0 : -1.0;
    if (eval.cp case final cp?) return cp / (cp.abs() + 300.0);
    return 0;
  }

  bool _brilliantCandidate(
    Position before,
    ViewBranch node,
    ClientEval pre,
    ClientEval post,
  ) {
    if (widget.variant != Variant.standard || pre.depth < 15 || post.depth < 15) {
      return false;
    }
    final move = node.sanMove.move;
    if (move is! NormalMove) return false;
    final piece = before.board.roleAt(move.from);
    if (piece != Role.queen &&
        piece != Role.rook &&
        piece != Role.bishop &&
        piece != Role.knight) {
      return false;
    }
    if (before.board.roleAt(move.to) != null) return false;
    if (pre.pvs.isEmpty || pre.pvs.first.moves.length < 2) return false;
    final reply = Move.parse(pre.pvs.first.moves[1]);
    if (reply is! NormalMove || reply.to != move.to) return false;
    if (!node.position.isLegal(reply)) return false;
    if (post.winningChances(before.turn) < -0.3) return false;
    return true;
  }

  _Grade _classify(Position before, ViewBranch move, ClientEval pre, ClientEval post) {
    if (move.nags?.contains(3) == true) return _Grade.brilliant;
    final best = pre.bestMove?.uci == move.sanMove.move.uci;
    final side = before.turn;
    final beforeChance = pre.winningChances(side);
    final afterChance = post.winningChances(side);
    final loss = (beforeChance - afterChance).clamp(0.0, 2.0).toDouble();
    if (best && _brilliantCandidate(before, move, pre, post)) {
      return _Grade.brilliant;
    }
    if (best) return _Grade.best;
    final verdict = MoveVerdict.fromShift(
      loss,
      hasBetterMove: true,
      winningChancesBefore: beforeChance,
      winningChancesAfter: afterChance,
    );
    return switch (verdict) {
      MoveVerdict.goodMove => loss < 0.02 ? _Grade.excellent : _Grade.good,
      MoveVerdict.notBest => _Grade.good,
      MoveVerdict.inaccuracy => _Grade.inaccuracy,
      MoveVerdict.mistake => _Grade.mistake,
      MoveVerdict.blunder => _Grade.blunder,
    };
  }

  Future<void> _start() async {
    if (_running) return;
    final generation = ++_generation;
    final mainline = widget.root.mainline.toList();
    ref.read(localReviewMarksProvider(widget.options.contextId.value).notifier).clear();
    setState(() {
      _moves.clear();
      _completed = 0;
      _total = mainline.length;
      _message = null;
      _running = true;
      _finished = false;
    });

    try {
      if (mainline.isEmpty) {
        setState(() {
          _message = 'Brak ruchów do analizy.';
          _running = false;
        });
        return;
      }
      var previous = await _evaluate(const <Step>[], generation, firstPosition: true);
      if (!mounted || generation != _generation) return;
      if (previous == null) {
        throw StateError('Stockfish nie zwrócił oceny pozycji początkowej.');
      }
      final steps = <Step>[];
      var path = UciPath.empty;
      for (var i = 0; i < mainline.length; i++) {
        if (!mounted || generation != _generation) return;
        final node = mainline[i];
        final before = i == 0 ? widget.root.position : mainline[i - 1].position;
        path = path + node.id;
        steps.add(Step(position: node.position, sanMove: node.sanMove));
        final after = node.position.isGameOver
            ? null
            : await _evaluate(steps, generation, firstPosition: false);
        if (!mounted || generation != _generation) return;

        if (previous != null && previous.depth >= 8 &&
            ((after != null && after.depth >= 8) || node.position.isCheckmate)) {
          final grade = node.position.isCheckmate
              ? _Grade.best
              : _classify(before, node, previous, after!);
          final best = previous.bestMove;
          String? bestSan;
          if (best != null && before.isLegal(best)) {
            bestSan = before.makeSan(best).$2;
          }
          final prefix = before.turn == Side.white
              ? '${before.fullmoves}.'
              : '${before.fullmoves}...';
          final advantage = after != null
              ? _advantage(after)
              : (before.turn == Side.white ? 1.0 : -1.0);
          setState(() {
            _moves.add((
              path: path,
              moveText: '$prefix ${node.sanMove.san}',
              beforeFen: before.fen,
              bestMove: bestSan,
              score: after?.evalString ?? 'Mat',
              side: before.turn,
              advantage: advantage,
              grade: grade,
            ));
          });
        }
        previous = after;
        setState(() => _completed = i + 1);
      }
      if (!mounted || generation != _generation) return;
      ref.read(localReviewMarksProvider(widget.options.contextId.value).notifier).replace({
        for (final move in _moves)
          move.path: (symbol: move.grade.symbol, color: move.grade.color),
      });
      setState(() {
        _finished = true;
        _message = _moves.length == mainline.length
            ? 'Ocena zakończona. Wyniki są przybliżone.'
            : 'Oceniono ${_moves.length} z ${mainline.length} ruchów. Niektóre pozycje nie miały wystarczającej oceny.';
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _message = 'Nie udało się przeanalizować partii: $error');
      }
    } finally {
      if (mounted && generation == _generation) {
        ref.read(positionEvaluatorProvider(_context).notifier).stop();
        setState(() => _running = false);
      }
    }
  }

  void _train(_ReviewedMove move) {
    Navigator.of(context).push(
      OfflineComputerGameScreen.buildRoute(
        initialVariant: widget.variant,
        initialFen: move.beforeFen,
      ),
    );
  }

  Widget _countColumn(String title, Side side, ColorScheme colors) {
    final moves = _moves.where((m) => m.side == side).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        for (final grade in _Grade.values)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Container(
                  width: 29,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  decoration: BoxDecoration(
                    color: grade.color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(grade.symbol, style: TextStyle(
                    color: grade.color,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  )),
                ),
                const SizedBox(width: 5),
                Expanded(child: Text(grade.label, style: const TextStyle(fontSize: 10))),
                Text('${moves.where((m) => m.grade == grade).length}',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Keep evaluator alive for the duration of review.
    ref.listen(positionEvaluatorProvider(_context), (_, _) {});
    final colors = ColorScheme.of(context);
    final selectedIndex = _moves.indexWhere((m) => m.path == widget.currentPath);
    final selected = selectedIndex < 0 ? null : _moves[selectedIndex];
    final failures = _moves.where((m) => m.grade.isError).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Card(
        color: colors.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Icon(Icons.analytics_outlined, color: colors.primary),
                const SizedBox(width: 8),
                const Expanded(child: Text('DEEP VIOLET • OCENA PARTII',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14))),
              ]),
              const SizedBox(height: 6),
              const Text('Analiza offline po zakończonej partii.',
                style: TextStyle(fontSize: 12)),
              const SizedBox(height: 12),
              Wrap(spacing: 8, children: [
                for (final mode in _ReviewMode.values)
                  ChoiceChip(
                    selected: _mode == mode,
                    onSelected: _running ? null : (_) => setState(() => _mode = mode),
                    label: Text(mode.title),
                  ),
              ]),
              const SizedBox(height: 4),
              Text(_mode.description, style: TextStyle(
                fontSize: 11, color: colors.onSurfaceVariant)),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _running ? _stop : _start,
                icon: Icon(_running ? Icons.stop_circle_outlined : Icons.auto_graph),
                label: Text(_running ? 'Zatrzymaj ocenę ($_completed/$_total)'
                    : _finished ? 'Oceń ponownie' : 'Ocena partii'),
              ),
              if (_running) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(value: _total == 0 ? null : _completed / _total),
              ],
              if (_message != null) Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_message!, style: const TextStyle(fontSize: 12)),
              ),
              if (_moves.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('WYKRES PRZEWAGI', style: TextStyle(
                  fontWeight: FontWeight.bold, color: colors.primary)),
                const SizedBox(height: 4),
                const Text('Powyżej środka: lepiej dla białych. Poniżej: dla czarnych.',
                  style: TextStyle(fontSize: 10)),
                const SizedBox(height: 8),
                SizedBox(height: 135, child: material.CustomPaint(
                  painter: _ReviewGraphPainter(
                    values: _moves.map((m) => m.advantage).toList(),
                    selected: selectedIndex,
                    lineColor: colors.primary,
                    foreground: colors.onSurfaceVariant,
                  ),
                  child: const SizedBox.expand(),
                )),
                const SizedBox(height: 4),
                Text('${_moves.length} ocenionych ruchów',
                  textAlign: TextAlign.end,
                  style: const TextStyle(fontSize: 10)),
                const Divider(height: 24),
                const Text('PODSUMOWANIE RUCHÓW',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _countColumn('BIAŁE', Side.white, colors)),
                  const SizedBox(width: 16),
                  Expanded(child: _countColumn('CZARNE', Side.black, colors)),
                ]),
                const Divider(height: 24),
                const Text('PRZEGLĄD RUCHÓW', style: TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 6),
                if (selected != null) Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: selected.grade.color.withValues(alpha: 0.11),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: selected.grade.color.withValues(alpha: 0.35)),
                  ),
                  child: Row(children: [
                    Text(selected.grade.symbol, style: TextStyle(
                      color: selected.grade.color, fontWeight: FontWeight.bold, fontSize: 21)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(
                      '${selected.moveText} • ${selected.grade.label}\n'
                      'Ocena: ${selected.score}'
                      '${selected.bestMove == null ? '' : ' • Najlepszy: ${selected.bestMove}'}',
                      style: const TextStyle(fontSize: 12),
                    )),
                  ]),
                ) else const Text('Przewiń partię lub wybierz ruch poniżej.',
                  style: TextStyle(fontSize: 11)),
                const SizedBox(height: 8),
                SizedBox(height: 54, child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _moves.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 5),
                  itemBuilder: (context, i) {
                    
                    final move = _moves[i];
                    final isSelected = move.path == widget.currentPath;
                    return InkWell(
                      onTap: () => widget.onJump(move.path),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 63),
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: move.grade.color.withValues(
                            alpha: isSelected ? 0.26 : 0.09,
                          ),
                          border: Border.all(
                            color: isSelected
                                ? move.grade.color
                                : move.grade.color.withValues(alpha: 0.2),
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              move.grade.symbol,
                              style: TextStyle(
                                color: move.grade.color,
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                              ),
                            ),
                            Text(
                              move.moveText,
                              style: const TextStyle(fontSize: 10),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                )),
                const SizedBox(height: 12),
                if (failures.isNotEmpty) ...[
                  Text(
                    'RUCHY DO POPRAWY (${failures.length})',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  for (final move in failures)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      onTap: () => widget.onJump(move.path),
                      leading: CircleAvatar(
                        radius: 16,
                        backgroundColor:
                            move.grade.color.withValues(alpha: 0.14),
                        child: Text(
                          move.grade.symbol,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: move.grade.color,
                          ),
                        ),
                      ),
                      title: Text(
                        '${move.moveText} • ${move.grade.label}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      subtitle: Text(
                        'Najlepszy ruch: ${move.bestMove ?? 'brak danych'}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.fitness_center, size: 18),
                        tooltip: 'Przećwicz tę pozycję',
                        onPressed: () => _train(move),
                      ),
                    ),
                ],
                const SizedBox(height: 10),
                Text(
                  'Oceny są przybliżone i zależą od głębokości '
                  'Stockfisha. „Genialny*” to heurystyka '
                  'poświęcenia lub oznaczenie !! z PGN, '
                  'a nie oficjalny algorytm Chess.com.',
                  style: TextStyle(
                    fontSize: 10,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ReviewGraphPainter extends material.CustomPainter {
  const _ReviewGraphPainter({
    required this.values,
    required this.selected,
    required this.lineColor,
    required this.foreground,
  });

  final List<double> values;
  final int selected;
  final Color lineColor;
  final Color foreground;

  @override
  void paint(material.Canvas canvas, material.Size size) {
    if (values.isEmpty) return;

    final middle = size.height / 2;

    canvas.drawLine(
      material.Offset(0, middle),
      material.Offset(size.width, middle),
      material.Paint()
        ..color = foreground.withValues(alpha: 0.35)
        ..strokeWidth = 1,
    );

    final points = <material.Offset>[];

    for (var i = 0; i < values.length; i++) {
      final x = values.length == 1
          ? size.width / 2
          : i * size.width / (values.length - 1);

      final y = middle -
          values[i].clamp(-1.0, 1.0) * (middle - 8);

      points.add(material.Offset(x, y));
    }

    if (points.length > 1) {
      final path = material.Path()
        ..moveTo(points[0].dx, points[0].dy);

      for (final point in points.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }

      canvas.drawPath(
        path,
        material.Paint()
          ..color = lineColor
          ..strokeWidth = 2.5
          ..strokeCap = material.StrokeCap.round
          ..style = material.PaintingStyle.stroke,
      );
    }

    if (selected >= 0 && selected < points.length) {
      final point = points[selected];

      canvas.drawLine(
        material.Offset(point.dx, 0),
        material.Offset(point.dx, size.height),
        material.Paint()
          ..color = foreground.withValues(alpha: 0.4)
          ..strokeWidth = 1,
      );

      canvas.drawCircle(
        point,
        5,
        material.Paint()..color = lineColor,
      );

      canvas.drawCircle(
        point,
        2,
        material.Paint()..color = Colors.white,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ReviewGraphPainter old) {
    return old.values != values ||
        old.selected != selected ||
        old.lineColor != lineColor ||
        old.foreground != foreground;
  }
}

