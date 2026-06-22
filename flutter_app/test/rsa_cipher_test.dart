import 'package:flutter_test/flutter_test.dart';
import 'package:lora_ble_chat/codec/rsa_cipher.dart';

void main() {
  // Par de demostracion (mismo que secrets.h del firmware).
  const p = 60013;
  const q = 60017;
  const e = 65537;
  const n = 3601800221; // p * q
  const d = 1778720129;

  group('RsaCipher', () {
    test('genera par valido', () {
      final kp = RsaCipher.generate(p, q, e);
      expect(kp.valid, isTrue);
      expect(kp.n, n);
      expect(kp.e, e);
      expect(kp.d, d);
    });

    test('e no coprimo => invalido', () {
      final kp = RsaCipher.generate(p, q, 2);
      expect(kp.valid, isFalse);
    });

    test('roundtrip cifrar/descifrar', () {
      const plain = 'Mensaje secreto para el broker';
      final cipher = RsaCipher.encryptString(plain, e, n);
      expect(RsaCipher.decryptToString(cipher, d, n), plain);
    });

    test('solo la clave privada correcta descifra', () {
      final cipher = RsaCipher.encryptString('hola', e, n);
      // Otra privada (otro modulo) no recupera el texto original.
      final wrong = RsaCipher.decryptToString(cipher, 7, 3601800221);
      expect(wrong == 'hola', isFalse);
    });
  });

  group('Interoperabilidad con el firmware C++', () {
    test('descifra hex publicado por la placa', () {
      // Vector "golden" producido por RsaCipher::encrypt para "Secreto".
      const hex =
          '837f2f84ddf91179a2ddf0056ccb0a91ddf911795e30010302ef21c9';
      final cipher = RsaCipher.hexToBytes(hex);
      expect(RsaCipher.decryptToString(cipher, d, n), 'Secreto');
    });
  });
}
