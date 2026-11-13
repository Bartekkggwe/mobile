
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lichess_mobile/src/model/analysis/analysis_controller.dart';
import 'package:lichess_mobile/src/model/analysis/analysis_preferences.dart';
import 'package:lichess_mobile/src/view/analysis/local_review_panel.dart';
import 'package:lichess_mobile/src/view/game/game_result_dialog.dart';
import 'package:lichess_mobile/src/widgets/pgn.dart';
import 'package:lichess_mobile/src/widgets/variations_bar.dart';
import 'package:material_ui/material_ui.dart';

class const AnalysisTreeView(final AnalysisOptions options) extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrlProvider = analysisControllerProvider(options);
    final analysisState = ref.watch(ctrlProvider).requireValue;
    final prefs = ref.watch(analysisPreferencesProvider);
    final localMarks = ref.watch(localReviewMarksProvider(options.contextId.value));

    final enableServerAnalysis =
        !options.isLichessGameAnalysis || prefs.enableServerAnalysis;
    final currentNode =
        analysisState.root.branchesOn(analysisState.currentPath).lastOrNull ??
        analysisState.root;

    return MovesWithVariationsBar(
      currentNode: currentNode,
      currentPath: analysisState.currentPath,
      showAnnotations: enableServerAnalysis && prefs.showAnnotations,
      onJump: (path) => ref.read(ctrlProvider.notifier).userJump(path),
      movesBuilder: (context, bottomPadding) => SingleChildScrollView(
        padding: EdgeInsets.only(bottom: bottomPadding),
        child: Column(
          children: [
            if (analysisState.isComputerAnalysisAllowed &&
                options is! ActiveCorrespondenceGame)
              LocalReviewPanel(
                key: ValueKey('review-${options.contextId.value}'),
                options: options,
                root: analysisState.root,
                variant: analysisState.variant,
                currentPath: analysisState.currentPath,
                onJump: (path) => ref.read(ctrlProvider.notifier).userJump(path),
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
              shouldShowAnnotations: enableServerAnalysis && prefs.showAnnotations,
              localReviewMarks: analysisState.isComputerAnalysisAllowed ? localMarks : const {},
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
