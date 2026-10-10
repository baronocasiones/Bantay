package ph.appbuilders.bantay_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MovementBaselineTest {
    @Test fun profileLearnsNormalVariabilityAndPersonalizesActivityContext() {
        var persisted: MovementBaselineSnapshot? = null
        val baseline = MovementBaseline(onPersist = { persisted = it })
        repeat(20) { baseline.observe(0.08) }

        assertEquals("still", baseline.classify(0.002, "unknown"))
        assertEquals("walking", baseline.classify(0.08, "unknown"))
        assertEquals("running", baseline.classify(0.2, "unknown"))
        assertEquals(20L, persisted?.windows)
        assertEquals(20L, baseline.snapshot().windows)
    }

    @Test fun insufficientOrInvalidProfileUsesExistingClassifier() {
        val baseline = MovementBaseline()
        assertEquals("walking", baseline.classify(0.2, "walking"))
        repeat(20) { baseline.observe(0.08) }
        assertEquals("unknown", baseline.classify(Double.NaN, "unknown"))
        baseline.observe(Double.NaN)
        assertEquals(20L, baseline.snapshot().windows)
    }

    @Test fun restoredProfileContinuesLearning() {
        val saved = MovementBaselineSnapshot(windows = 20, meanVariance = 0.1, squaredDeviationTotal = 0.0)
        val baseline = MovementBaseline(initial = saved)
        baseline.observe(0.2)
        assertTrue(baseline.snapshot().meanVariance > saved.meanVariance)
        assertFalse(baseline.snapshot().windows == saved.windows)
    }
}
