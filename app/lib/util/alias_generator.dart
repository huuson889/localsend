import 'dart:math';

import 'package:localsend_app/gen/strings.g.dart';

String generateRandomAlias() {
  final random = Random();
  final adj = t.aliasGenerator.adjectives;
  final fruits = t.aliasGenerator.fruits;

  // The combination of both is locale dependent too.
  return t.aliasGenerator.combination(
    adjective: adj[random.nextInt(adj.length)],
    fruit: fruits[random.nextInt(fruits.length)],
  );
}

/// Whether [alias] is one of the auto-generated random aliases (in the
/// current locale). Used to migrate old auto-generated defaults to the
/// device name without overwriting aliases the user typed themselves.
bool isRandomAlias(String alias) {
  final adjectives = t.aliasGenerator.adjectives;
  final fruits = t.aliasGenerator.fruits;
  for (final adjective in adjectives) {
    for (final fruit in fruits) {
      if (t.aliasGenerator.combination(adjective: adjective, fruit: fruit) == alias) {
        return true;
      }
    }
  }
  return false;
}
