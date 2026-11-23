package app.streamsetu.core.model

/** Adds the pair only when the key is not there yet (Map.putIfAbsent needs Android 7; this app supports Android 5.1). */
fun <K, V> MutableMap<K, V>.putIfMissing(key: K, value: V) { if (!containsKey(key)) put(key, value) }
