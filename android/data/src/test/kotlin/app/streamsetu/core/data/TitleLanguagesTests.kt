package app.streamsetu.core.data

import app.streamsetu.core.data.repo.TitleLanguages
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TitleLanguagesTests {
    @Test fun aLanguageInBracketsIsRead() {
        assertEquals("English", TitleLanguages.of("Whalefall (2026) (English) (HDCAM)"))
        assertEquals("Telugu", TitleLanguages.of("Lucky Baskhar [Telugu]"))
        assertEquals("Turkish", TitleLanguages.of("American Conspiracy: The Octopus Murders (Turkish)"))
    }

    @Test fun aLanguageWordOutsideBracketsIsLeftAlone() {
        assertNull(TitleLanguages.of("The Hindi Teacher (2019)"))
    }

    @Test fun theFolderNameIsUsedWhenTheTitleSaysNothing() {
        assertEquals("Tamil", TitleLanguages.of("Leo (2023)", "TAMIL MOVIES 2023"))
        assertNull(TitleLanguages.of("Leo (2023)", "Action"))
    }

    @Test fun brackets_withSeveralWords_stillFindTheLanguage() {
        assertEquals("Hindi", TitleLanguages.of("Pathaan (2023) (Hindi DD5.1)"))
    }
}
