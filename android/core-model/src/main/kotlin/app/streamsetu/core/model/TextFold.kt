package app.streamsetu.core.model

import java.text.Normalizer

/**
 * The one shared first step of "does this text match that text": accents removed (non-spacing marks only, so Devanagari and Telugu vowel signs stay) and lower case. Search and the Sports classifier
 * start from it. Persisted identity keys (IdentityKey), artwork matching (ArtworkNames, ArtworkMatchDecision), the weekly list and Trakt keep their own folds on purpose: each differs in what
 * else it strips, and changing one would change stored keys or match results.
 */
object TextFold {
    private val nonSpacingMarks = Regex("\\p{Mn}+")
    fun accents(s: String): String = Normalizer.normalize(s, Normalizer.Form.NFD).replace(nonSpacingMarks, "").lowercase()
}
