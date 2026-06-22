import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lora_ble_chat/codec/demo_keys.dart';
import 'package:lora_ble_chat/codec/rsa_oaep.dart';

void main() {
  final rsa = RsaOaep.fromPem(
    privateKeyPem: DemoKeys.privateKeyPem,
    publicKeyPem: DemoKeys.publicKeyPem,
  );

  test('carga claves desde PEM', () {
    expect(rsa.canDecrypt, isTrue);
    expect(rsa.canEncrypt, isTrue);
  });

  test('roundtrip cifrar (publica) / descifrar (privada)', () {
    const plain = 'Mensaje de produccion FdAS';
    final b64 = rsa.encryptToBase64(plain);
    final out = utf8.decode(rsa.decryptFromBase64(b64));
    expect(out, plain);
  });

  test('clave privada distinta no descifra', () {
    final b64 = rsa.encryptToBase64('hola');
    final other = RsaOaep.fromPem(privateKeyPem: _otherPrivateKey);
    final out = other.decryptFromBase64(b64);
    // Falla el padding OAEP => devuelve vacio.
    expect(out, isEmpty);
  });

  group('Interoperabilidad con OpenSSL/mbedtls', () {
    test('descifra un cifrado RSA-OAEP-SHA256 generado por OpenSSL', () {
      // Vector "golden": "Mensaje de produccion FdAS" cifrado con la clave
      // publica via OpenSSL (mismo esquema que produce mbedtls en la placa).
      const b64 =
          'f+sJnqCohWyfLHpSquLSgi7YNIfOKbVRdWpfbUawezv2ClJrGnnNQnMDn/LesneWw4AI'
          'Gj+PjurzVsy65Blu3WwPrLXyL5WNrqWk0OH6rzXfTV6ufqsZ1qbMq7GzCNKCq7k6+4T'
          'EGwJ6/86sDxePuQzA8rECIhqwacwvRLrJOw7/wESaJWz0c59WYtBJrpGsanHu8Dhsml'
          'L0bCMTjXbWeQ5SDuE/IhhJpPGLhcWGoSqtiZPxKW0Cnn3i4Ikh9cLTPRDFX+IqlMefv'
          'umF2BfMq4bY4gloGCC4PIQpVLc1ZUqfqCrmR99LD00PywGvduO/BqppS3Qsn+LOQbBm'
          'Pacvow==';
      final out = utf8.decode(rsa.decryptFromBase64(b64));
      expect(out, 'Mensaje de produccion FdAS');
    });
  });
}

// Otra clave privada RSA-2048 valida (no corresponde a la publica de DemoKeys).
const String _otherPrivateKey = '''-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC9obaFtQ+tCtR/
cRANcuDrGCkpgDylHYcRFf+o2tRxAXISGO1iwPwlQK3G3wesjAbaOSwzDVC1kmVj
2kBHp90aWUxQYjN9MF7VFxIhBTIINjI8QJ7Uxz+TMQ62h0IQf0GMsKCPpjFACwcx
wsPcnQJcwASwF2EZH6dbbIpgIv6Gz3PST1/CbUQ6gUCrnfdxsV5E5e08I/k2OCgE
aEDQDQmkAFEbOZ5gRawJZ0SFNNuGAowRW6oypqB5jQmgmHfllaS09uBN9K/rcSC+
DzVHFjNzon9QlZzZW+G56YOf7+7aSwOgjBocgxtj4+7ezdhr21fiihAVo2gKMCz8
ybtj8WclAgMBAAECggEAAMSK100TByxSt+wJQ0StIcaImXZqHcZaKaOL1BnZX6vA
fnpDW8b+6QJeBxQYFTFr8FjoPjyrkFCgwHVoaoyExKU1PeNn5KCG1xive3ATR8fl
uYC5eTsP8tScA/kq4fjh7GPlV9o1u4ClQs+luLBEti4WLBsBdaHp14uU89awbnNJ
cqvLJEeczECqY81Upj7SQeJujih2EhshzY5ZCc6qvMhYeXz2cYcqLO7m5RTN2iL9
7RqwmVaL/vTAoRKPf3Z6McExOXoxu++83JiSAJa3qL/fZxbO6m99lCHTdmmv8/B8
YhXbLYuXRJCsRQC2LqfjqwvUG1aPktE7unST+OFA8QKBgQDeqOUw1u13vT7Sk1uK
gVEO63VciWIofaqtKwzALO9n0bX/lEQgQV63Fi28RRDwQjPw6S4xf5rTSI+O2SiW
+0uUDXHmJvFkkxNIF7u5axic7KCqyFFtNjFyqi9w9YmnuJ9dCC3+7e9Md/2KHVCP
U7pMgeIdxFmyMPKM6UM1WoSVswKBgQDaBsUOsD0mq3INKUC0Gg1+RDEbEFQ/czYX
IUCOo2Zu5S9ge0fj6y3/JaR41F7Wat9E34sGLhTOUG3MoumKDvn+a6YfdMJydIjQ
m/B+mbApsek9vCnPPcnwEZZxoZJOkSqyQ+AaeReGuxKdB0vmpjX1P7HEz1t76njq
/VxNUEhTxwKBgQCFdnFitAHFOx9T81X0kIz4x3QikorOwHy0rdBHxOd/sHlKCCJJ
v0U5s0aYykFb8iLWLb8tllJEgQLj2hD1Zw2nYeO60+7vnST6mpdAjgxDy6aGl+oO
72P2WkJzkAoCCa0kg4mmfBJrIKVNy0KFluddgqD5vL8TCznn8s4BRg+g9wKBgQC9
3mFj3kUS1QF4xrErZvjTOi2NhRXpP7seP34J+fCtqHcuzY2YxemDplNqSn/guKeB
Qi+/DQhfd5l3OXSqH0rErxi3kiX4KNYw3Wx9w/evB9m4QpIigYvHvnlGsc9JDpCh
OA0E4OmFEosuJvmJfrvEvVhhrbbc3h+5fTURu1WRZwKBgBMLYy6p+HFW+LbYuHIw
psvwJyhYqF3oOxyYIuxGZV5tkWzhl6yL+5uL8td6XIZjep/Fb5HqePx2kFeyNUzD
P5cmPb5sDeJDC2BISdyttGvVAbvGzuJqwj8msW4+ZlprLvJjdrbXxLPE6+CIgaAZ
6b5aJas5EEQGx6+0R4AvbJmc
-----END PRIVATE KEY-----''';
