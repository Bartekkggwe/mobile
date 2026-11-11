
import 'package:dartchess/dartchess.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lichess_mobile/src/db/openings_database.dart';
import 'package:lichess_mobile/src/model/analysis/analysis_controller.dart';
import 'package:lichess_mobile/src/model/common/chess.dart';
import 'package:lichess_mobile/src/model/common/id.dart';
import 'package:lichess_mobile/src/utils/navigation.dart';
import 'package:lichess_mobile/src/view/analysis/analysis_screen.dart';
import 'package:lichess_mobile/src/widgets/platform.dart';
import 'package:material_ui/material_ui.dart';

/// Jeden debiut wraz z sekwencją ruchów z bazy Lichess.
class _OpeningLine {
  const _OpeningLine(this.eco, this.name, this.pgn);

  final String eco;
  final String name;
  final String pgn;
}

class const OpeningLibraryScreen({super.key})
    extends ConsumerStatefulWidget {
  static Route<void> buildRoute() {
    return buildScreenRoute(
      screen: const OpeningLibraryScreen(),
    );
  }

  @override
  ConsumerState<OpeningLibraryScreen> createState() =>
      _OpeningLibraryScreenState();
}

class _OpeningLibraryScreenState
    extends ConsumerState<OpeningLibraryScreen> {
  final _searchController = TextEditingController();

  String? _ecoGroup;
  late Future<List<_OpeningLine>> _results;

  @override
  void initState() {
    super.initState();
    _results = _findOpenings();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<List<_OpeningLine>> _findOpenings() async {
    final db = await ref.read(openingsDatabaseProvider.future);

    final filters = <String>[];
    final args = <Object?>[];
    final query = _searchController.text.trim();

    if (_ecoGroup != null) {
      filters.add('eco LIKE ?');
      args.add('$_ecoGroup%');
    }

    if (query.isNotEmpty) {
      filters.add('(name LIKE ? OR eco LIKE ?)');
      args.addAll(['%$query%', '%$query%']);
    }

    final rows = await db.query(
      'openings',
      columns: ['eco', 'name', 'pgn'],
      where: filters.isEmpty
          ? null
          : filters.join(' AND '),
      whereArgs: args,
      orderBy: 'eco ASC, name COLLATE NOCASE ASC',
      limit: 100,
    );

    return [
      for (final row in rows)
        _OpeningLine(
          row['eco'] as String,
          row['name'] as String,
          row['pgn'] as String,
        ),
    ];
  }

  void _refresh() {
    setState(() {
      _results = _findOpenings();
    });
  }

  void _openInAnalysis(_OpeningLine opening) {
    final id = StringId(
      'opening-${opening.eco}-${opening.name.hashCode}',
    );

    Navigator.of(context).push(
      AnalysisScreen.buildRoute(
        AnalysisOptions.pgn(
          id: id,
          orientation: Side.white,
          initialMoveCursor: 0,
          pgn: opening.pgn,
          variant: Variant.standard,
          isComputerAnalysisAllowed: true,
        ),
      ),
    );
  }

  void _showOpening(_OpeningLine opening) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            20, 8, 20, 24,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${opening.eco} • ${opening.name}',
                  style: Theme.of(
                    sheetContext,
                  ).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                const Text('Sekwencja ruchów:'),
                const SizedBox(height: 6),
                SelectableText(
                  opening.pgn,
                  style: const TextStyle(
                    fontSize: 16,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      _openInAnalysis(opening);
                    },
                    icon: const Icon(Icons.play_arrow),
                    label: const Text(
                      'Odtwórz na szachownicy',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return PlatformScaffold(
      appBar: const PlatformAppBar(
        title: Text('Encyklopedia debiutów'),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                16, 16, 16, 8,
              ),
              child: TextField(
                controller: _searchController,
                onChanged: (_) => _refresh(),
                decoration: const InputDecoration(
                  hintText: 'Nazwa debiutu albo kod ECO',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
              ),
              child: Row(
                children: [
                  for (final group in <String?>[
                    null,
                    'A',
                    'B',
                    'C',
                    'D',
                    'E',
                  ])
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                      ),
                      child: FilterChip(
                        label: Text(
                          group ?? 'Wszystkie',
                        ),
                        selected: _ecoGroup == group,
                        onSelected: (_) {
                          _ecoGroup = group;
                          _refresh();
                        },
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                16, 8, 16, 4,
              ),
              child: Text(
                'Biblioteka offline • maksymalnie 100 wyników naraz',
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ),
            Expanded(
              child: FutureBuilder<List<_OpeningLine>>(
                future: _results,
                builder: (context, snapshot) {
                  if (snapshot.connectionState !=
                      ConnectionState.done) {
                    return const Center(
                      child: CircularProgressIndicator(),
                    );
                  }

                  if (snapshot.hasError) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'Nie udało się otworzyć bazy: ${snapshot.error}',
                        ),
                      ),
                    );
                  }

                  final openings =
                      snapshot.data ??
                      const <_OpeningLine>[];

                  if (openings.isEmpty) {
                    return const Center(
                      child: Text(
                        'Nie znaleziono takiego debiutu.',
                      ),
                    );
                  }

                  return ListView.separated(
                    itemCount: openings.length,
                    separatorBuilder: (_, index) =>
                        const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final opening = openings[index];

                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: colors.primary
                              .withValues(alpha: 0.14),
                          child: Text(
                            opening.eco,
                            style: TextStyle(
                              color: colors.primary,
                              fontSize: 11,
                            ),
                          ),
                        ),
                        title: Text(opening.name),
                        subtitle: Text(
                          opening.pgn,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(
                          Icons.chevron_right,
                        ),
                        onTap: () =>
                            _showOpening(opening),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
