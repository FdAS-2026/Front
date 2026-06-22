/// Claves RSA-2048 de DEMOSTRACION para el proyecto de catedra.
///
/// ADVERTENCIA DE PRODUCCION: una clave privada nunca debe distribuirse dentro
/// de una app. En produccion real, genera tu propio par y carga la privada en
/// el dispositivo de confianza que consume el broker (idealmente desde
/// almacenamiento seguro / variable de entorno, no en el codigo fuente).
/// Reemplaza estos valores con `flutter run --dart-define` o un secret store.
///
/// La publica debe coincidir con la de `secrets.h` del firmware.
class DemoKeys {
  static const String publicKeyPem = '''-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAp8oRqNgHqbkre6KPdEWy
mmWowLD+n67uN7IDt1z4KdgR0dTQ9LLIdDoZveZDgfAWtdWr1YpQcby2iT3x65X+
zmAGQuPdtNzbAmIbxJ8+xOh0LcKb8GE2rey/povVVoJjIbSDQ3vpbBorj4QLISb3
xzgj0cBehh5k3ycYq1OtBALozOg3l+g6EO0Aat9B0lfSzT6eyG16KmR8G7Lt9ZIF
UF8TINFhF8x6Z3ulkaHlasLxPB2az+fKH9eQQNGab6kYEfoOXKJf7o62U9INFBJd
KrIMZU5xYaEW3y5xiLwaU1LdUnXgTiBt35iMXPciF8EYrE+vhb/8XLleHk7DQ8k5
7wIDAQAB
-----END PUBLIC KEY-----''';

  static const String privateKeyPem = '''-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCnyhGo2AepuSt7
oo90RbKaZajAsP6fru43sgO3XPgp2BHR1ND0ssh0Ohm95kOB8Ba11avVilBxvLaJ
PfHrlf7OYAZC49203NsCYhvEnz7E6HQtwpvwYTat7L+mi9VWgmMhtINDe+lsGiuP
hAshJvfHOCPRwF6GHmTfJxirU60EAujM6DeX6DoQ7QBq30HSV9LNPp7IbXoqZHwb
su31kgVQXxMg0WEXzHpne6WRoeVqwvE8HZrP58of15BA0ZpvqRgR+g5col/ujrZT
0g0UEl0qsgxlTnFhoRbfLnGIvBpTUt1SdeBOIG3fmIxc9yIXwRisT6+Fv/xcuV4e
TsNDyTnvAgMBAAECggEAD7wxf8YSoeYNn+CU13CZ2UTjWH7AwjTjfjGhi5aaZ0Iu
GaF9nxUNG2k/dMGdXxgm6RKKtNHtzVzHOYOnplJAvRXgQHGiHw3/M/ADbqMIferW
ylvPx/E18YWcS4Adl6lOpqCJFtEOCOdDYogdixRedD5djZQeyTEcgJjoBVkphpCg
PPvHLN4Zi3LV0GT2BhhArmme3iiWKdWs67gwKaqjfcf0wP7mmxwhnPjEK7y2Yo60
Q/dLk9ocZeu6hp4gcecWp7KBWoFzGh6zIofPZ4W17t60QzAEaSO5G/0SyiYtRhsW
jAUI7HhaPfkdPO/G1f+GpryyTwSNcfsHOGSGZJB6wQKBgQDjrsIMNr6agO5T1eww
VoCmsyKxbn6e1aAX7Bke+AxGjG1++Isb/FKwxrCU5g5wbCRSCLa7lM3v/fuGObP3
WElt0975CWTNgTBwPzz2j2DLd+ceCsB6BfX3Ov+JBrcyTPb7FoDDCMcXksScLokj
QL9Zez+AgtD7zpVbn5mMiE8zUQKBgQC8qFp6qQCz6HNAEOB5PUQavyBJ/zw8HYq2
RIw8C1Fhcej51aYsCB40Ns/Zas9usZlsMIEh6U6oZapevFzn0VUlK3rsy9WfRjj7
zaZAcvx77mnVCHx9GYSK3lLH4l08Jv/4Q6OaADwmeAHfb0hvEA53NEGKaQf5iQoN
LqlErrHJPwKBgG/hVCFEVWz+ph40JJesKhPAOvANZ9MNDloy/jUlloKkRrn50AG0
f722JNdGJRpBSae1+HU8reWcXJicij6k95AsaIjfgNUrAm5l5MMTuXDCPqOYjPRp
MXCHYUIoNqVVBJhlemhcS9jdmhdVFrZn/p8t3Qp9Pcw+u04GoyFXafPBAoGAGG2c
OaHEi4cf1T3aMxixxtzUq4A3JnmUyoEZv3SftwRu7Fqzx6PNdWlbhIWGEolAmne1
YNS68KcpZlbxmLrMUaHNqvfB03veSQyZ6GJ7OvjmD0WoCPLS7MBY67Tt6aoLHvRz
LK+3GiwT4gCg2nCzzs+fZPKwq6kI+if+lvwf3TUCgYEAmC0oClg5NDnycqDAAzWl
z9YD6tST+WxOp5Iy3Pu5W8l5gXn8uSRUGwhvlQjq0dAqYCX6t8JYHeJ+AX+qbsih
6PxI3m4nkfWwCWuAWTnaV1OS+e/yUHHpHmfZrIWDJaRgMvDh59TW5v3HyrBZhsFp
NZX4tk8SwrrdlfcjsRD249s=
-----END PRIVATE KEY-----''';
}
