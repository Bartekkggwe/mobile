import 'dart:async';
import 'dart:convert';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:multistockfish/multistockfish.dart';

enum GameMode {
  humanVsGpt('Ty kontra ChatGPT'),
  gptVsStockfish('ChatGPT kontra Stockfish'),
  humanVsStockfish('Ty kontra Stockfish');

  const GameMode(this.label);
  final String label;
}

class ArenaPage extends StatefulWidget {
  const ArenaPage({super.key});

  @override
  State<ArenaPage> createState() => _ArenaPageState();
}

class _ArenaPageState extends State<ArenaPage> {
  static const _storage = FlutterSecureStorage();
  static const _purple = Color(0xffa65aff);
  static const _light = Color(0xffdfc5ff);
  static const _dark = Color(0xff7352a1);
  static const _pieceGlyphs = <String, String>{
    'K': '♔',
    'Q': '♕',
    'R': '♖',
    'B': '♗',
    'N': '♘',
    'P': '♙',
    'k': '♚',
    'q': '♛',
    'r': '♜',
    'b': '♝',
    'n': '♞',
    'p': '♟',
  };

  Position _position = Chess.initial;
  GameMode _mode = GameMode.humanVsGpt;
  final List<String> _sans = <String>[];
  String _key = '';
  String _model = 'gpt-4o-mini';
  String? _selected;
  String? _lastFrom;
  String? _lastTo;
  String _status = 'Wybierz tryb i zagraj.';
  Stockfish? _engine;
  Completer<String>? _bestMoveCompleter;
  bool _busy = false;
  bool _autoRunning = false;
  int _generation = 0;
  int _thinkingMs = 800;

  bool get _humanTurn => _mode != GameMode.gptVsStockfish && _position.turn == Side.white;

  bool get _gptTurn =>
      (_mode == GameMode.humanVsGpt && _position.turn == Side.black) ||
      (_mode == GameMode.gptVsStockfish && _position.turn == Side.white);

  bool get _stockfishTurn =>
      (_mode == GameMode.humanVsStockfish && _position.turn == Side.black) ||
      (_mode == GameMode.gptVsStockfish && _position.turn == Side.black);

  @override
  void initState() {
    super.initState();
    unawaited(_loadSettings());
    unawaited(_initStockfish());
  }

  Future<void> _loadSettings() async {
    try {
      final key = await _storage.read(key: 'openai_api_key') ?? '';
      final model = await _storage.read(key: 'openai_model') ?? 'gpt-4o-mini';
      if (mounted)
        setState(() {
          _key = key;
          _model = model;
        });
    } catch (e) {
      if (mounted) _showError('Nie udało się odczytać ustawień: $e');
    }
  }

  void _onStockfishLine(String line) {
    if (!line.startsWith('bestmove ')) return;
    final parts = line.trim().split(RegExp(r'\s+'));
    final completer = _bestMoveCompleter;
    if (parts.length >= 2 && completer != null && !completer.isCompleted) {
      completer.complete(parts[1]);
    }
  }

  Future<void> _initStockfish() async {
    try {
      // multistockfish exposes engine output through an onStdout callback,
      // not a stdout Stream.
      final engine = await Stockfish.create(
        flavor: StockfishFlavor.light,
        onStdout: _onStockfishLine,
      );
      if (!mounted) {
        await engine.dispose();
        return;
      }
      setState(() {
        _engine = engine;
      });
    } catch (e) {
      if (mounted) _showError('Stockfish nie wystartował: $e');
    }
  }

  @override
  void dispose() {
    _generation++;
    final engine = _engine;
    if (engine != null) unawaited(engine.dispose());
    super.dispose();
  }

  void _showError(String message) {
    if (mounted) setState(() => _status = message);
  }

  void _reset() {
    if (_busy && _stockfishTurn) _engine?.stdin = 'stop';
    _generation++;
    setState(() {
      _autoRunning = false;
      _position = Chess.initial;
      _sans.clear();
      _selected = null;
      _lastFrom = null;
      _lastTo = null;
      _status = 'Nowa partia. Białe zaczynają.';
    });
  }

  void _restoreChatGame() {
    _reset();
    _applyMove('e2e4');
    _applyMove('e7e5');
    setState(() {
      _mode = GameMode.humanVsGpt;
      _status = 'Partia z czatu: 1. e4 e5. Teraz Twój ruch.';
    });
  }

  Move? _parseLegal(String uci) {
    final move = Move.parse(uci);
    if (move == null) return null;
    final normalized = move is NormalMove ? _position.normalizeMove(move) : move;
    return _position.isLegal(normalized) ? normalized : null;
  }

  bool _applyMove(String uci) {
    final move = _parseLegal(uci);
    if (move == null) return false;
    final san = _position.toSan(move);
    final raw = move.uci;
    setState(() {
      _position = _position.play(move);
      _sans.add(san);
      _selected = null;
      _lastFrom = raw.substring(0, 2);
      _lastTo = raw.substring(2, 4);
      if (_position.isCheckmate) {
        _status = 'Szach-mat! Wygrywają ' + (_position.turn == Side.white ? 'czarne.' : 'białe.');
        _autoRunning = false;
      } else if (_position.isStalemate || _position.isInsufficientMaterial) {
        _status = 'Remis.';
        _autoRunning = false;
      } else {
        _status =
            (_position.turn == Side.white ? 'Białe' : 'Czarne') +
            ' na ruchu' +
            (_position.isCheck ? ' • szach!' : '.');
      }
    });
    return true;
  }

  void _tapSquare(String name) {
    if (_busy || !_humanTurn || _position.isGameOver) return;
    final square = Square.fromName(name);
    final piece = _position.board.pieceAt(square);
    if (_selected == null) {
      if (piece?.color == Side.white) setState(() => _selected = name);
      return;
    }
    if (_selected == name) {
      setState(() => _selected = null);
      return;
    }
    final origin = Square.fromName(_selected!);
    final moving = _position.board.pieceAt(origin);
    String uci = _selected! + name;
    if (moving?.role == Role.pawn && name.endsWith('8')) uci += 'q';
    if (_applyMove(uci)) {
      unawaited(_step());
    } else if (piece?.color == Side.white) {
      setState(() => _selected = name);
    } else {
      setState(() => _selected = null);
    }
  }

  List<String> _legalUciMoves() {
    final moves = <String>[];
    for (final entry in _position.legalMoves.entries) {
      final piece = _position.board.pieceAt(entry.key);
      for (final to in entry.value.squares) {
        final prefix = entry.key.name + to.name;
        if (piece?.role == Role.pawn && (to.name.endsWith('8') || to.name.endsWith('1'))) {
          for (final letter in ['q', 'r', 'b', 'n']) {
            moves.add(prefix + letter);
          }
        } else {
          moves.add(prefix);
        }
      }
    }
    return moves;
  }

  Future<String> _askChatGpt() async {
    if (_key.trim().isEmpty) {
      throw StateError('W ustawieniach wpisz klucz OpenAI API.');
    }
    final legal = _legalUciMoves();
    final response = await http
        .post(
          Uri.parse('https://api.openai.com/v1/chat/completions'),
          headers: {'Authorization': 'Bearer ${_key.trim()}', 'Content-Type': 'application/json'},
          body: jsonEncode({
            'model': _model,
            'max_tokens': 30,
            'messages': [
              {
                'role': 'system',
                'content':
                    'Grasz w szachy bez dostępu do silnika. '
                    'Wybierz JEDEN ruch tylko z podanej listy legalnych ruchów UCI. '
                    'Odpowiedz wyłącznie jednym ruchem UCI (np. g1f3). '
                    'Żadnych wyjaśnień i znaczników Markdown.',
              },
              {
                'role': 'user',
                'content':
                    'Pozycja FEN: ${_position.fen}\n'
                    'Lista legalnych ruchów UCI: ${legal.join(' ')}\n'
                    'Wybierz swój ruch.',
              },
            ],
          }),
        )
        .timeout(const Duration(seconds: 35));
    if (response.statusCode != 200) {
      final body = response.body.length > 280 ? response.body.substring(0, 280) : response.body;
      throw StateError('OpenAI HTTP ${response.statusCode}: $body');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = data['choices'] as List<dynamic>;
    final message = choices.first['message'] as Map<String, dynamic>;
    final content = (message['content'] as String? ?? '').trim().toLowerCase();
    final match = RegExp(r'[a-h][1-8][a-h][1-8][qrbn]?').firstMatch(content);
    final answer = match?.group(0);
    if (answer == null || !legal.contains(answer)) {
      throw StateError('ChatGPT wybrał nielegalny ruch: $content');
    }
    return answer;
  }

  Future<String> _askStockfish() async {
    final engine = _engine;
    if (engine == null) throw StateError('Stockfish jeszcze się uruchamia.');
    final completer = Completer<String>();
    _bestMoveCompleter = completer;
    engine.stdin = 'position fen ${_position.fen}';
    engine.stdin = 'go movetime $_thinkingMs';
    try {
      return await completer.future.timeout(const Duration(seconds: 20));
    } finally {
      if (identical(_bestMoveCompleter, completer)) _bestMoveCompleter = null;
    }
  }

  Future<void> _step() async {
    if (_busy || _position.isGameOver || _humanTurn) return;
    if (_mode == GameMode.gptVsStockfish && !_autoRunning) return;
    final generation = _generation;
    final gptTurn = _gptTurn;
    if (gptTurn && _key.isEmpty) {
      _showError('Dodaj klucz OpenAI API w ustawieniach (ikona klucza).');
      if (_autoRunning) setState(() => _autoRunning = false);
      return;
    }
    if (_stockfishTurn && _engine == null) {
      _showError('Stockfish jeszcze się uruchamia.');
      if (_autoRunning) setState(() => _autoRunning = false);
      return;
    }
    setState(() {
      _busy = true;
      _status = gptTurn ? 'ChatGPT myśli...' : 'Stockfish liczy...';
    });
    try {
      final uci = gptTurn ? await _askChatGpt() : await _askStockfish();
      if (!mounted || generation != _generation) return;
      if (!_applyMove(uci)) throw StateError('Nielegalny ruch od AI: $uci');
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          _status = 'Błąd: $e';
          _autoRunning = false;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (_mode == GameMode.gptVsStockfish && _autoRunning && !_position.isGameOver) {
          unawaited(Future<void>.delayed(const Duration(milliseconds: 500), () => _step()));
        }
      }
    }
  }

  void _toggleAuto() {
    if (_mode != GameMode.gptVsStockfish) return;
    setState(() {
      _autoRunning = !_autoRunning;
      _status = _autoRunning ? 'Automatyczna partia trwa.' : 'Partia wstrzymana.';
    });
    if (_autoRunning) unawaited(_step());
  }

  Future<void> _openSettings() async {
    final keyController = TextEditingController(text: _key);
    final modelController = TextEditingController(text: _model);
    var milliseconds = _thinkingMs;
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, updateDialog) => AlertDialog(
          backgroundColor: const Color(0xff1c1530),
          title: const Text('Ustawienia AI'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Klucz OpenAI API jest przechowywany w bezpiecznej pamięci '
                  'telefonu. Zapytania są rozliczane przez OpenAI.',
                  style: TextStyle(fontSize: 12, color: Colors.white70),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: keyController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'OpenAI API key',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: modelController,
                  decoration: const InputDecoration(
                    labelText: 'Model',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Text('Stockfish: $milliseconds ms/ruch'),
                Slider(
                  min: 200,
                  max: 3000,
                  divisions: 14,
                  value: milliseconds.toDouble(),
                  onChanged: (value) => updateDialog(() => milliseconds = value.round()),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Anuluj'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Zapisz'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (saved == true) {
      setState(() {
        _key = keyController.text.trim();
        _model = modelController.text.trim().isEmpty ? 'gpt-4o-mini' : modelController.text.trim();
        _thinkingMs = milliseconds;
      });
      try {
        await _storage.write(key: 'openai_api_key', value: _key);
        await _storage.write(key: 'openai_model', value: _model);
      } catch (e) {
        _showError('Nie udało się zapisać klucza: $e');
      }
    }
    keyController.dispose();
    modelController.dispose();
  }

  String _pieceCode(Piece piece) {
    final letter = switch (piece.role) {
      Role.king => 'k',
      Role.queen => 'q',
      Role.rook => 'r',
      Role.bishop => 'b',
      Role.knight => 'n',
      Role.pawn => 'p',
    };
    return piece.color == Side.white ? letter.toUpperCase() : letter;
  }

  Widget _buildBoard() {
    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 8),
          itemCount: 64,
          itemBuilder: (context, i) {
            final file = i % 8;
            final rank = 7 - (i ~/ 8);
            final name = 'abcdefgh'[file] + (rank + 1).toString();
            final piece = _position.board.pieceAt(Square.fromName(name));
            final isLight = (file + rank).isOdd;
            final isSelected = name == _selected;
            final isLastMove = name == _lastFrom || name == _lastTo;
            final isTarget =
                _selected != null &&
                _position.legalMovesOf(Square.fromName(_selected!)).has(Square.fromName(name));
            final bg = isSelected
                ? const Color(0xffd02fff)
                : isLastMove
                ? const Color(0xff9a6fbc)
                : isLight
                ? _light
                : _dark;
            return GestureDetector(
              onTap: () => _tapSquare(name),
              child: Container(
                color: bg,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (isTarget)
                      Center(
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: const BoxDecoration(
                            color: Color(0x9940106a),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    if (piece != null)
                      Center(
                        child: Text(
                          _pieceGlyphs[_pieceCode(piece)] ?? '?',
                          style: TextStyle(
                            fontSize: 34,
                            height: 1,
                            color: piece.color == Side.white
                                ? const Color(0xffffffff)
                                : const Color(0xff160d26),
                            shadows: [
                              Shadow(
                                color: piece.color == Side.white
                                    ? const Color(0xff322044)
                                    : const Color(0xffe9dcf5),
                                blurRadius: 2,
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (file == 0)
                      Positioned(
                        top: 2,
                        left: 3,
                        child: Text(
                          (rank + 1).toString(),
                          style: TextStyle(
                            fontSize: 10,
                            color: isLight ? const Color(0xff62477d) : Colors.white70,
                          ),
                        ),
                      ),
                    if (rank == 0)
                      Positioned(
                        right: 2,
                        bottom: 1,
                        child: Text(
                          'abcdefgh'[file],
                          style: TextStyle(
                            fontSize: 10,
                            color: isLight ? const Color(0xff62477d) : Colors.white70,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final history = <String>[];
    for (var i = 0; i < _sans.length; i += 2) {
      history.add('${i ~/ 2 + 1}. ${_sans[i]}' + (i + 1 < _sans.length ? '  ${_sans[i + 1]}' : ''));
    }
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xff0c0919),
        title: const Text(
          '♟ AI CHESS ARENA',
          style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.0),
        ),
        actions: [
          IconButton(
            tooltip: 'Klucz API i ustawienia',
            onPressed: _openSettings,
            icon: const Icon(Icons.key, color: _purple),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 26),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xff201635),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<GameMode>(
                    value: _mode,
                    isExpanded: true,
                    items: GameMode.values
                        .map(
                          (mode) =>
                              DropdownMenuItem<GameMode>(value: mode, child: Text(mode.label)),
                        )
                        .toList(),
                    onChanged: (mode) {
                      if (mode == null) return;
                      _reset();
                      setState(() => _mode = mode);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'CZARNE',
                    style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 2),
                  ),
                  Text(
                    _mode == GameMode.humanVsGpt ? 'CHATGPT' : 'STOCKFISH',
                    style: const TextStyle(color: _purple),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _buildBoard(),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'BIAŁE',
                    style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 2),
                  ),
                  Text(
                    _mode == GameMode.gptVsStockfish ? 'CHATGPT' : 'TY',
                    style: const TextStyle(color: _purple),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xff24163a),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xff4b2e70)),
                ),
                child: Row(
                  children: [
                    if (_busy)
                      const Padding(
                        padding: EdgeInsets.only(right: 10),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    Expanded(child: Text(_status)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _reset,
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Nowa partia'),
                  ),
                  if (_mode == GameMode.gptVsStockfish)
                    OutlinedButton.icon(
                      onPressed: _toggleAuto,
                      icon: Icon(_autoRunning ? Icons.pause : Icons.play_arrow),
                      label: Text(_autoRunning ? 'Pauza' : 'Start'),
                    ),
                  OutlinedButton.icon(
                    onPressed: _restoreChatGame,
                    icon: const Icon(Icons.forum_outlined),
                    label: const Text('1. e4 e5 z czatu'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'ZAPIS PARTII',
                style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 2, color: _purple),
              ),
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(minHeight: 65),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xff191127),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  history.isEmpty ? 'Jeszcze nie wykonano ruchów.' : history.join('   '),
                  style: const TextStyle(fontSize: 15, fontFamily: 'monospace', height: 1.7),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Ruchy: dotknij figury i pola docelowego. '
                'Promocja automatycznie na hetmana. '
                'W trybach ChatGPT wymagany jest własny klucz OpenAI API; '
                'Stockfish działa lokalnie i bez internetu.',
                style: TextStyle(fontSize: 12, color: Colors.white60),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
