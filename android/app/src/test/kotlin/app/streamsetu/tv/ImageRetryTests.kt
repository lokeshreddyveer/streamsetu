package app.streamsetu.tv

import okhttp3.*
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

class ImageRetryTests {
    private fun client(retry: ImageRetry, answer: (Int) -> Response) : OkHttpClient {
        var n = 0
        return OkHttpClient.Builder().addInterceptor(retry).addInterceptor(Interceptor { chain -> answer(++n).newBuilder().request(chain.request()).build() }).build()
    }
    private fun ok(code: Int) = Response.Builder().request(Request.Builder().url("http://x/").build()).protocol(Protocol.HTTP_1_1).code(code).message("m").body(ResponseBody.create(null, "")).build()
    private val get = Request.Builder().url("http://x/p.jpg").build()

    @Test fun aDroppedConnectionIsTriedAgainWithGrowingWaits() {
        val waits = ArrayList<Long>()
        val c = client(ImageRetry(sleep = { waits += it })) { n -> if (n < 3) throw IOException("reset") else ok(200) }
        assertEquals(200, c.newCall(get).execute().code); assertEquals(listOf(400L, 1200L), waits)
    }

    @Test fun aServerErrorIsRetriedButAMissingPictureIsNot() {
        val waits = ArrayList<Long>()
        assertEquals(200, client(ImageRetry(sleep = { waits += it })) { n -> if (n == 1) ok(503) else ok(200) }.newCall(get).execute().code); assertEquals(1, waits.size)
        waits.clear(); var calls = 0
        assertEquals(404, client(ImageRetry(sleep = { waits += it })) { calls++; ok(404) }.newCall(get).execute().code); assertEquals(1, calls); assertTrue(waits.isEmpty())
    }

    @Test fun afterTheLastTryTheFailureIsPassedOn() {
        var calls = 0
        val c = client(ImageRetry(sleep = {})) { calls++; throw IOException("down") }
        assertTrue(runCatching { c.newCall(get).execute() }.exceptionOrNull() is IOException); assertEquals(3, calls)
    }
}
