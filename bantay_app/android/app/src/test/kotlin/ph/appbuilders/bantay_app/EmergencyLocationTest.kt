package ph.appbuilders.bantay_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EmergencyLocationTest {
    @Test
    fun smsSuffixContainsRoundedCoordinatesAndAccuracy() {
        val location = EmergencyLocation(
            latitude = 14.599512,
            longitude = 120.984223,
            capturedAtEpochMs = 1_000L,
            accuracyMeters = 12.2f,
        )

        assertEquals(
            "GPS: 14.59951,120.98422 +/- 13m",
            location.toSmsSuffix(),
        )
        assertTrue(location.toSmsSuffix().all { it.code < 128 })
    }

    @Test
    fun usableLocationMustBeRecentValidAndAccurateEnough() {
        val fresh = EmergencyLocation(14.6, 121.0, 10_000L, 100f)
        assertTrue(fresh.isUsable(nowEpochMs = 40_000L, maxAgeMs = 30_000L))
        assertFalse(fresh.isUsable(nowEpochMs = 40_001L, maxAgeMs = 30_000L))

        val inaccurate = fresh.copy(accuracyMeters = 5_001f)
        assertFalse(inaccurate.isUsable(nowEpochMs = 20_000L, maxAgeMs = 30_000L))

        val future = fresh.copy(capturedAtEpochMs = 20_001L)
        assertFalse(future.isUsable(nowEpochMs = 20_000L, maxAgeMs = 30_000L))

        val invalid = fresh.copy(latitude = 91.0)
        assertFalse(invalid.isUsable(nowEpochMs = 20_000L, maxAgeMs = 30_000L))
    }
}
