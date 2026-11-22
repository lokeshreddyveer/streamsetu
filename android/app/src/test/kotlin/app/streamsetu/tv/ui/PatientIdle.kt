package app.streamsetu.tv.ui

import org.junit.rules.TestRule
import org.junit.runner.Description
import org.junit.runners.model.Statement
import java.util.concurrent.TimeUnit

/**
 * The Compose tests wait for the app to be idle with Espresso's default of 60 seconds. With four test JVMs sharing a machine (and a long run of earlier tests warming each one) a heavy
 * screen can need longer than that for the same work it does in a few seconds alone, which showed up as "Compose did not get idle" in tests that pass every time when run on their own.
 * A longer limit changes nothing the test asserts (a screen that really never settles still fails, after five minutes).
 */
class PatientIdle : TestRule {
    override fun apply(base: Statement, description: Description) = object : Statement() {
        override fun evaluate() {
            // (Espresso is on the test run's class path through Compose's test library, not on the compile one: reached by name.)
            runCatching {
                val policies = Class.forName("androidx.test.espresso.IdlingPolicies")
                for (m in listOf("setMasterPolicyTimeout", "setIdlingResourceTimeout")) policies.getMethod(m, Long::class.javaPrimitiveType, TimeUnit::class.java).invoke(null, 5L, TimeUnit.MINUTES)
            }
            base.evaluate()
        }
    }
}
