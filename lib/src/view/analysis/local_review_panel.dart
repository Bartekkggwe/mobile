
import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
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

/// Nie używać do podpowiedzi podczas aktywnej partii online.
/// Panel jest uruchamiany wyłącznie z analizy, jeśli engine jest dozwolony.
enum _Grade {
  brilliant('Genialny*', '!!', Color(0xFF25C7DD)),
  best('Najlepszy', '★', Color(0xFF66C79A)),
  excellent('Świetny', '!', Color(0xFF48B8DB)),
  good('Dobry', '✓', Color(0xFF9BCB77)),
  inaccuracy('Niedokładność', '?!', Color(0xFFE5B65B)),
  mistake('Błąd', '?', Color(0xFFEA965B)),
  blunder('Podstawka', '??', Color(0xFFE76880));

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
  _Grade grade,
});

class const LocalReviewPanel({
  required final AnalysisOptions options,
  required final ViewRoot root,
  required final Variant variant,
  required final void Function(UciPath) onJump,
  super.key,
}) extends ConsumerStatefulWidget {
  @override
  ConsumerState<LocalReviewPanel> createState() => _LocalReviewPanelState();
}

class _LocalReviewPanelState extends ConsumerState<LocalReviewPanel> {
  final List<_ReviewedMove> _moves = [];
  bool _running = false;
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
    if (oldWidget.root.position.fen != widget.root.position.fen ||
        oldLine != newLine) {
      _generation++;
      _activeSubscription?.cancel();
      if (_waiting case final waiting? when !waiting.isCompleted) {
        waiting.complete(null);
      }
      _moves.clear();
      _running = false;
      _completed = 0;
      _total = 0;
      _message = null;
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
    if (mounted) setState(() => _running = false);
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
      searchTime: const Duration(seconds: 2),
      multiPv: 1,
      threatMode: false,
      initialPosition: widget.root.position,
      steps: IList(steps),
    );

    ClientEval? latest;
    final waiter = Completer<ClientEval?>();
    _waiting = waiter;
    final subscription =
        ref.read(positionEvaluatorProvider(_context).notifier).evaluate(work).listen(
      (event) {
        if (generation != _generation) return;
        latest = event.$2;
        if (event.$2.depth >= 14 && !waiter.isCompleted) {
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
        Duration(seconds: firstPosition ? 20 : 7),
        onTimeout: () => latest,
      );
    } finally {
      await subscription.cancel();
      if (identical(_activeSubscription, subscription)) {
        _activeSubscription = null;
      }
      if (identical(_waiting, waiter)) _waiting = null;
    }
  }

  /// Ostrożna heurystyka: najlepszy ruch poświęca ciężką/lekką figurę
  /// na pustym polu, a główna linia silnika pokazuje jej zbicie.
  /// Nie jest to algorytm Chess.com, dlatego nazwa ma gwiazdkę.
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

  _Grade _classify(
    Position before,
    ViewBranch move,
    ClientEval pre,
    ClientEval post,
  ) {
    // Ręcznie zatwierdzona adnotacja PGN ma pierwszeństwo.
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
    setState(() {
      _moves.clear();
      _completed = 0;
      _total = mainline.length;
      _message = null;
      _running = true;
    });

    try {
      if (mainline.isEmpty) {
        setState(() {
          _message = 'Brak ruchów do analizy.';
          _running = false;
        });
        return;
      }

      var previous = await _evaluate(
        const <Step>[], generation, firstPosition: true,
      );
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
          setState(() {
            _moves.add((
              path: path,
              moveText: '$prefix ${node.sanMove.san}',
              beforeFen: before.fen,
              bestMove: bestSan,
              score: after?.evalString ?? 'Mat',
              grade: grade,
            ));
          });
        }

        previous = after;
        setState(() => _completed = i + 1);
      }

      if (mounted && generation == _generation) {
        setState(() {
          _message = _moves.isEmpty
              ? 'Silnik nie zwrócił dostatecznie głębokich ocen.'
              : 'Analiza zakończona. Oceny są przybliżone.';
        });
      }
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

  @override
  Widget build(BuildContext context) {
    // Utrzymuje evaluator przy życiu do końca przeglądu.
    ref.listen(positionEvaluatorProvider(_context), (_, _) {});
    final colors = ColorScheme.of(context);
    final failures = _moves.where((m) => m.grade.isError).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Card(
        color: colors.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          leading: Icon(Icons.query_stats, color: colors.primary),
          title: const Text(
            'DEEP VIOLET • ANALIZA',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
          ),
          subtitle: Text(
            _running
                ? 'Stockfish: $_completed / $_total ruchów'
                : _moves.isEmpty
                    ? 'Oceń całą partię bez logowania'
                    : '${_moves.length} ocen • ${failures.length} błędów',
          ),
          childrenPadding: const EdgeInsets.all(12),
          children: [
            if (_running)
              LinearProgressIndicator(
                value: _total == 0 ? null : _completed / _total,
              ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _running ? _stop : _start,
              icon: Icon(_running ? Icons.stop_circle_outlined : Icons.play_arrow),
              label: Text(_running ? 'Zatrzymaj analizę' : 'Oceń całą partię'),
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_message!, style: const TextStyle(fontSize: 12)),
              ),
            if (_moves.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final grade in _Grade.values)
                    if (_moves.any((move) => move.grade == grade))
                      Chip(
                        label: Text(
                          '${grade.symbol} ${grade.label}: '
                          '${_moves.where((m) => m.grade == grade).length}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        backgroundColor: grade.color.withValues(alpha: 0.10),
                        side: BorderSide(
                          color: grade.color.withValues(alpha: 0.35),
                        ),
                      ),
                ],
              ),
              const Divider(height: 20),
              for (final move in _moves)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        onTap: () => widget.onJump(move.path),
                        leading: CircleAvatar(
                          radius: 17,
                          backgroundColor: move.grade.color.withValues(alpha: 0.15),
                          child: Text(
                            move.grade.symbol,
                            style: TextStyle(
                              color: move.grade.color,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        title: Text(
                          '${move.moveText} • ${move.grade.label}',
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: Text(
                          'Ocena: ${move.score}'
                          '${move.bestMove == null ? '' : ' • Najlepszy: ${move.bestMove}'}',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                      if (move.grade.isError)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () => _train(move),
                            icon: const Icon(Icons.fitness_center, size: 16),
                            label: const Text('Przećwicz tę pozycję'),
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                '* „Genialny” to ostrożna heurystyka poświęcenia '
                'lub oznaczenie !! z PGN. Nie jest identyczna z Chess.com. '
                'Klasyfikacja zależy od głębokości obliczeń Stockfisha.',
                style: TextStyle(fontSize: 10, color: colors.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
