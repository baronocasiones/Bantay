package ph.appbuilders.bantay_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CascadeDetectorTest {
    private class Trace {
        var t = 0.0
        fun feed(detector: CascadeDetector, count: Int, x: Double, y: Double, z: Double): FallImpact? {
            var impact: FallImpact? = null
            repeat(count) {
                impact = detector.add(t, x, y, z) ?: impact
                t += 20.0
            }
            return impact
        }
    }

    @Test fun impactRotationStillnessEmitsOnce() {
        val detector = CascadeDetector()
        val trace = Trace()
        trace.feed(detector, 50, 0.0, 0.0, 1.0)
        trace.feed(detector, 1, 0.0, 0.0, 6.0)
        val impact = trace.feed(detector, 160, 1.0, 0.0, 0.0)
        assertNotNull(impact)
        assertEquals(6.0, impact!!.peakG, 0.01)
        assertTrue(impact.stillnessSeconds >= 2)
        assertEquals("confirmed", detector.diagnostics.rejectReason)
    }

    @Test fun impactWithoutRotationExposesRejectReason() {
        val detector = CascadeDetector()
        val trace = Trace()
        trace.feed(detector, 50, 0.0, 0.0, 1.0)
        trace.feed(detector, 1, 0.0, 0.0, 6.0)
        val impact = trace.feed(detector, 160, 0.0, 0.0, 1.0)
        assertEquals(null, impact)
        assertTrue(detector.diagnostics.impactThresholdCrossed)
        assertEquals("rotation_timeout", detector.diagnostics.rejectReason)
    }

    @Test fun impactWith48DegreeRotationIsRejected() {
        val detector = CascadeDetector()
        val trace = Trace()
        trace.feed(detector, 50, 0.0, 0.0, 1.0)
        trace.feed(detector, 1, 0.0, 0.0, 6.0)
        val impact = trace.feed(detector, 160, 0.7431, 0.0, 0.6691)
        assertEquals(null, impact)
        assertEquals("rotation_timeout", detector.diagnostics.rejectReason)
    }

    @Test fun impactWithMoreThan60DegreeRotationStillConfirms() {
        val detector = CascadeDetector()
        val trace = Trace()
        trace.feed(detector, 50, 0.0, 0.0, 1.0)
        trace.feed(detector, 1, 0.0, 0.0, 6.0)
        val impact = trace.feed(detector, 160, 0.9165, 0.0, 0.4)
        assertNotNull(impact)
        assertTrue(impact!!.peakG > CascadeDetector.IMPACT_THRESHOLD_G)
        assertEquals("confirmed", detector.diagnostics.rejectReason)
    }

    @Test fun noImpactDoesNotCrossThreshold() {
        val detector = CascadeDetector()
        Trace().feed(detector, 100, 0.0, 0.0, 1.0)
        assertFalse(detector.diagnostics.impactThresholdCrossed)
        assertEquals(0.0, detector.diagnostics.lastPeakG, 0.01)
    }

    @Test fun handlingBumpBelowFiveGDoesNotStartCandidate() {
        val detector = CascadeDetector()
        val trace = Trace()
        trace.feed(detector, 50, 0.0, 0.0, 1.0)
        trace.feed(detector, 1, 0.0, 0.0, 4.65)
        assertFalse(detector.diagnostics.impactThresholdCrossed)
        assertEquals(0.0, detector.diagnostics.lastPeakG, 0.01)
    }
}
