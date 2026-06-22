import 'dart:convert';
import 'dart:typed_data';

/// Codec Huffman compatible byte a byte con el firmware LoRaPeer (C++).
///
/// Formato del buffer codificado (igual que `HuffmanCodec.cpp`):
///   [uint32 LE]  longitud original en bytes (0 => buffer vacio)
///   [uint16 LE]  cantidad de simbolos distintos (m)
///   m * { [uint8 simbolo][uint32 LE frecuencia] }
///   bits empaquetados de los codigos (MSB primero)
///
/// El arbol se reconstruye con un orden total (frecuencia, secuencia de
/// creacion) identico al del firmware, garantizando interoperabilidad.
class HuffmanCodec {
  Uint8List encodeString(String input) =>
      encode(utf8.encode(input));

  String decodeToString(List<int> data) =>
      utf8.decode(decode(data), allowMalformed: true);

  Uint8List encode(List<int> input) {
    final out = <int>[];
    if (input.isEmpty) return Uint8List.fromList(out);

    final freq = List<int>.filled(256, 0);
    for (final c in input) {
      freq[c & 0xFF]++;
    }

    final symbols = <int>[];
    final freqs = <int>[];
    for (var s = 0; s < 256; s++) {
      if (freq[s] != 0) {
        symbols.add(s);
        freqs.add(freq[s]);
      }
    }

    final tree = _buildTree(symbols, freqs);
    final codes = List<String>.filled(256, '');
    _buildCodes(tree, tree.root, '', codes);

    // Cabecera.
    _putU32(out, input.length);
    out.add(symbols.length & 0xFF);
    out.add((symbols.length >> 8) & 0xFF);
    for (var i = 0; i < symbols.length; i++) {
      out.add(symbols[i]);
      _putU32(out, freqs[i]);
    }

    // Bits empaquetados (MSB primero).
    var cur = 0;
    var bits = 0;
    for (final c in input) {
      for (final bit in codes[c & 0xFF].codeUnits) {
        cur = (cur << 1) | (bit == 0x31 ? 1 : 0); // '1'
        if (++bits == 8) {
          out.add(cur & 0xFF);
          cur = 0;
          bits = 0;
        }
      }
    }
    if (bits > 0) {
      cur <<= (8 - bits);
      out.add(cur & 0xFF);
    }
    return Uint8List.fromList(out);
  }

  List<int> decode(List<int> data) {
    final out = <int>[];
    if (data.length < 6) return out;

    var pos = 0;
    final origLen = _getU32(data, pos);
    pos += 4;
    if (origLen == 0) return out;

    final m = data[pos] | (data[pos + 1] << 8);
    pos += 2;
    if (m == 0) return out;

    final symbols = <int>[];
    final freqs = <int>[];
    for (var i = 0; i < m; i++) {
      if (pos + 5 > data.length) return [];
      symbols.add(data[pos++]);
      freqs.add(_getU32(data, pos));
      pos += 4;
    }

    final tree = _buildTree(symbols, freqs);
    if (tree.root < 0) return out;

    final singleLeaf =
        tree.left[tree.root] >= 0 && tree.right[tree.root] < 0;
    var node = tree.root;

    for (var i = pos; i < data.length && out.length < origLen; i++) {
      for (var b = 7; b >= 0 && out.length < origLen; b--) {
        final bit = (data[i] >> b) & 1;
        if (singleLeaf) {
          out.add(tree.symbol[tree.left[tree.root]]);
          continue;
        }
        node = bit == 1 ? tree.right[node] : tree.left[node];
        if (node < 0) return [];
        if (tree.left[node] < 0 && tree.right[node] < 0) {
          out.add(tree.symbol[node]);
          node = tree.root;
        }
      }
    }

    if (out.length != origLen) return [];
    return out;
  }

  _Tree _buildTree(List<int> symbols, List<int> freqs) {
    final tree = _Tree();
    if (symbols.isEmpty) {
      tree.root = -1;
      return tree;
    }

    final active = <int>[];
    for (var i = 0; i < symbols.length; i++) {
      tree.add(symbols[i], freqs[i], -1, -1);
      active.add(tree.size - 1);
    }

    if (active.length == 1) {
      final only = active[0];
      tree.add(tree.symbol[only], tree.freq[only], only, -1);
      tree.root = tree.size - 1;
      return tree;
    }

    while (active.length > 1) {
      final a = _popMin(active, tree);
      final b = _popMin(active, tree);
      final minSym =
          tree.symbol[a] < tree.symbol[b] ? tree.symbol[a] : tree.symbol[b];
      tree.add(minSym, tree.freq[a] + tree.freq[b], a, b);
      active.add(tree.size - 1);
    }
    tree.root = active[0];
    return tree;
  }

  /// Selecciona el nodo activo menor por orden total (freq, seq de creacion).
  int _popMin(List<int> active, _Tree tree) {
    var best = 0;
    for (var i = 1; i < active.length; i++) {
      final fi = tree.freq[active[i]];
      final fb = tree.freq[active[best]];
      if (fi < fb || (fi == fb && active[i] < active[best])) {
        best = i;
      }
    }
    final node = active[best];
    active.removeAt(best);
    return node;
  }

  void _buildCodes(_Tree tree, int node, String prefix, List<String> codes) {
    if (node < 0) return;
    if (tree.left[node] < 0 && tree.right[node] < 0) {
      codes[tree.symbol[node]] = prefix.isEmpty ? '0' : prefix;
      return;
    }
    _buildCodes(tree, tree.left[node], '${prefix}0', codes);
    _buildCodes(tree, tree.right[node], '${prefix}1', codes);
  }

  void _putU32(List<int> out, int v) {
    out.add(v & 0xFF);
    out.add((v >> 8) & 0xFF);
    out.add((v >> 16) & 0xFF);
    out.add((v >> 24) & 0xFF);
  }

  int _getU32(List<int> d, int pos) {
    return d[pos] |
        (d[pos + 1] << 8) |
        (d[pos + 2] << 16) |
        (d[pos + 3] << 24);
  }
}

/// Arbol Huffman almacenado en arreglos paralelos (indice = nodo).
class _Tree {
  final List<int> symbol = [];
  final List<int> freq = [];
  final List<int> left = [];
  final List<int> right = [];
  int root = -1;

  int get size => symbol.length;

  void add(int sym, int f, int l, int r) {
    symbol.add(sym);
    freq.add(f);
    left.add(l);
    right.add(r);
  }
}
