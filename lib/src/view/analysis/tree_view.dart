
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lichess_mobile/src/model/analysis/analysis_controller.dart';
import 'package:lichess_mobile/src/model/analysis/analysis_preferences.dart';
import 'package:lichess_mobile/src/model/common/node.dart';
import 'package:lichess_mobile/src/model/common/uci.dart';
import 'package:lichess_mobile/src/view/game/game_result_dialog.dart';
import 'package:lichess_mobile/src/widgets/pgn.dart';
import 'package:lichess_mobile/src/widgets/variations_bar.dart';
import 'package:material_ui/material_ui.dart';

enum _MoveGrade {
  brilliant('Genialny', '!!', Color(0xFF21C7D9)),
  good('Dobry', '!', Color(0xFF51C98B)),
  interesting('Ciekawy', '!?', Color(0xFFB38AFF)),
  forced('Jedyny', '□', Color(0xFF91A5C0)),
  inaccuracy('Niedokładność', '?!', Color(0xFFE7B657)),
  mistake('Błąd', '?', Color(0xFFEF9856)),
  blunder('Podstawka', '??', Color(0xFFEA6176));

  const _MoveGrade(this.label, this.symbol, this.color);

  final String label;
  final String symbol;
  final Color color;

  bool get isError =>
      this == _MoveGrade.inaccuracy ||
      this == _MoveGrade.mistake ||
      this == _MoveGrade.blunder;
}

_MoveGrade? _gradeFromNags(Iterable<int>? nags) {
  if (nags == null) return null;

  if (nags.contains(4)) return _MoveGrade.blunder;
  if (nags.contains(2)) return _MoveGrade.mistake;
  if (nags.contains(6)) return _MoveGrade.inaccuracy;
  if (nags.contains(3)) return _MoveGrade.brilliant;
  if (nags.contains(1)) return _MoveGrade.good;
  if (nags.contains(5)) return _MoveGrade.interesting;
  if (nags.contains(8)) return _MoveGrade.forced;

  return null;
}

typedef _RatedMove = ({
  UciPath path,
  _MoveGrade grade,
});

List<_RatedMove> _ratedMainlineMoves(ViewRoot root) {
  final rated = <_RatedMove>[];
  var path = UciPath.empty;

  for (final node in root.mainline) {
    path = path + node.id;
    final grade = _gradeFromNags(node.nags);

    if (grade != null) {
      rated.add((path: path, grade: grade));
    }
  }

  return rated;
}

UciPath? _nextRatedMove(
  List<_RatedMove> moves,
  UciPath current, {
  bool errorsOnly = false,
}) {
  final relevant = errorsOnly
      ? moves.where((move) => move.grade.isError)
      : moves;

  if (relevant.isEmpty) return null;

  for (final move in relevant) {
    if (move.path.size > current.size) {
      return move.path;
    }
  }

  return relevant.first.path;
}

class const AnalysisTreeView(final AnalysisOptions options)
    extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrlProvider = analysisControllerProvider(options);
    final analysisState = ref.watch(ctrlProvider).requireValue;
    final prefs = ref.watch(analysisPreferencesProvider);

    final enableServerAnalysis =
        !options.isLichessGameAnalysis || prefs.enableServerAnalysis;

    final currentNode =
        analysisState.root.branchesOn(analysisState.currentPath).lastOrNull ??
        analysisState.root;

    final showGrades = enableServerAnalysis && prefs.showAnnotations;
    final ratedMoves = showGrades
        ? _ratedMainlineMoves(analysisState.root)
        : <_RatedMove>[];

    return MovesWithVariationsBar(
      currentNode: currentNode,
      currentPath: analysisState.currentPath,
      showAnnotations: showGrades,
      onJump: (path) => ref.read(ctrlProvider.notifier).userJump(path),
      movesBuilder: (context, bottomPadding) => SingleChildScrollView(
        padding: EdgeInsets.only(bottom: bottomPadding),
        child: Column(
          children: [
            if (ratedMoves.isNotEmpty)
              _MoveReviewHeader(
                currentNode: currentNode,
                currentPath: analysisState.currentPath,
                ratedMoves: ratedMoves,
                onJump: (path) =>
                    ref.read(ctrlProvider.notifier).userJump(path),
              ),
            DebouncedPgnTreeView(
              root: analysisState.root,
              currentPath: analysisState.currentPath,
              livePath: analysisState.pathToLiveMove,
              pgnRootComments: analysisState.pgnRootComments,
              notifier: ref.read(ctrlProvider.notifier),
              showTopDivider: false,
              shouldShowComputerAnalysis: enableServerAnalysis,
              shouldShowComments: enableServerAnalysis && prefs.showPgnComments,
              shouldShowAnnotations: showGrades,
              premovePaths: analysisState.forecast?.lines,
              displayMode: prefs.inlineNotation ? .inlineNotation : .twoColumn,
            ),
            if (analysisState.archivedGame != null)
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: GameResult(game: analysisState.archivedGame!),
              ),
          ],
        ),
      ),
    );
  }
}

class const _MoveReviewHeader({
  required final ViewNode currentNode,
  required final UciPath currentPath,
  required final List<_RatedMove> ratedMoves,
  required final void Function(UciPath) onJump,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    final selectedGrade = _gradeFromNags(currentNode.nags);
    final mistakes = ratedMoves.where((move) => move.grade.isError).length;

    final nextRated = _nextRatedMove(ratedMoves, currentPath);
    final nextMistake = _nextRatedMove(
      ratedMoves,
      currentPath,
      errorsOnly: true,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      child: Card(
        color: colors.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          leading: Icon(
            Icons.analytics_outlined,
            color: colors.primary,
          ),
          title: const Text(
            'ANALIZA RUCHÓW',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          subtitle: Text(
            '${ratedMoves.length} ocen • $mistakes niedokładności i błędów',
            style: const TextStyle(fontSize: 11),
          ),
          childrenPadding: const EdgeInsets.all(12),
          children: [
            if (selectedGrade != null)
              ListTile(
                dense: true,
                leading: Icon(
                  Icons.stars_rounded,
                  color: selectedGrade.color,
                ),
                title: Text(
                  selectedGrade.label,
                  style: TextStyle(
                    color: selectedGrade.color,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                subtitle: const Text('Ocena wybranego ruchu'),
              ),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final grade in _MoveGrade.values)
                  if (ratedMoves.any((move) => move.grade == grade))
                    _GradeCounter(
                      grade: grade,
                      count: ratedMoves
                          .where((move) => move.grade == grade)
                          .length,
                    ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  onPressed: nextRated == null
                      ? null
                      : () => onJump(nextRated),
                  icon: const Icon(Icons.skip_next, size: 18),
                  label: const Text('Następna ocena'),
                ),
                if (mistakes > 0)
                  OutlinedButton.icon(
                    onPressed: nextMistake == null
                        ? null
                        : () => onJump(nextMistake),
                    icon: const Icon(
                      Icons.report_problem_outlined,
                      size: 18,
                    ),
                    label: const Text('Następny błąd'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Oceny pochodzą z adnotacji PGN. '
              'Nie są automatycznie obliczane przez Stockfish.',
              style: TextStyle(
                color: colors.onSurfaceVariant,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class const _GradeCounter({
  required final _MoveGrade grade,
  required final int count,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 9,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: grade.color.withValues(alpha: 0.10),
        border: Border.all(
          color: grade.color.withValues(alpha: 0.35),
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '${grade.symbol} ${grade.label}: $count',
        style: TextStyle(
          color: grade.color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
