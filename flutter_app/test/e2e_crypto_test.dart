import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lora_ble_chat/codec/e2e_crypto.dart';

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('X25519 vectores RFC 7748 (interop con mbedtls)', () {
    // RFC 7748 seccion 6.1.
    const alicePriv =
        '77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a';
    const alicePub =
        '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a';
    const bobPriv =
        '5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb';
    const bobPub =
        'de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f';

    test('la publica derivada de la privada coincide con el vector', () async {
      final alice = await E2ECrypto.keyPairFromPrivate(_hex(alicePriv));
      expect(_toHex(alice.publicKey), alicePub);
      final bob = await E2ECrypto.keyPairFromPrivate(_hex(bobPriv));
      expect(_toHex(bob.publicKey), bobPub);
    });

    test('clave AES derivada coincide con la de la placa ESP32 fisica', () async {
      // Vector capturado por serial de la placa real (E2ERFC): deriveAesKey
      // con la privada de Alice y la publica de Bob (HKDF del secreto RFC).
      final alice = await E2ECrypto.keyPairFromPrivate(_hex(alicePriv));
      final key = await E2ECrypto.deriveAesKey(alice, _hex(bobPub));
      expect(_toHex(key),
          '975885f9b87932660aa033f833f4e35fec3d2b26fdecfaff6bf2c9899e1b15da');
    });
  });

  group('E2E ECDH + AES-GCM', () {
    test('ambos lados derivan la misma clave (ECDH simetrico)', () async {
      final a = await E2ECrypto.generateKeyPair();
      final b = await E2ECrypto.generateKeyPair();
      final ka = await E2ECrypto.deriveAesKey(a, b.publicKey);
      final kb = await E2ECrypto.deriveAesKey(b, a.publicKey);
      expect(ka, equals(kb));
    });

    test('A cifra para B, B descifra', () async {
      final a = await E2ECrypto.generateKeyPair();
      final b = await E2ECrypto.generateKeyPair();
      final keyAB = await E2ECrypto.deriveAesKey(a, b.publicKey);
      final keyBA = await E2ECrypto.deriveAesKey(b, a.publicKey);

      final packet = await E2ECrypto.encrypt(keyAB, utf8.encode('Hola Beto'));
      final clear = await E2ECrypto.decrypt(keyBA, packet);
      expect(utf8.decode(clear!), 'Hola Beto');
    });

    test('un tercero con otra clave no descifra', () async {
      final a = await E2ECrypto.generateKeyPair();
      final b = await E2ECrypto.generateKeyPair();
      final eve = await E2ECrypto.generateKeyPair();
      final keyAB = await E2ECrypto.deriveAesKey(a, b.publicKey);
      final keyEve = await E2ECrypto.deriveAesKey(eve, a.publicKey);

      final packet = await E2ECrypto.encrypt(keyAB, utf8.encode('secreto'));
      final clear = await E2ECrypto.decrypt(keyEve, packet);
      expect(clear, isNull); // tag GCM invalido
    });

    test('paquete tiene formato nonce(12)+ct+tag(16)', () async {
      final a = await E2ECrypto.generateKeyPair();
      final b = await E2ECrypto.generateKeyPair();
      final key = await E2ECrypto.deriveAesKey(a, b.publicKey);
      final packet = await E2ECrypto.encrypt(key, utf8.encode('hi'));
      // 12 nonce + 2 texto + 16 tag = 30
      expect(packet.length, 12 + 2 + 16);
    });
  });
}
