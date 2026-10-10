package ph.appbuilders.bantay_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GuardianAlertTextTest {
    @Test
    fun withLocationAddsCoordinatesAndAccuracyToExistingMessage() {
        val location = EmergencyLocation(14.599512, 120.984223, 1_000L, 12f)

        assertEquals(
            "BANTAY ALERT: A possible fall. GPS: 14.59951,120.98422 +/- 12m",
            GuardianAlertText.withLocation("BANTAY ALERT: A possible fall.", location),
        )
    }

    @Test
    fun withMissingLocationClearlyMarksUnavailable() {
        assertEquals(
            "BANTAY ALERT: I need help. GPS unavailable.",
            GuardianAlertText.withLocation("BANTAY ALERT: I need help.", null),
        )
    }

    @Test
    fun fallAlertFitsOneSmsPartWithLocation() {
        val body = GuardianAlertText.singlePart(
            body = GuardianAlertText.fall(9.0, "11:51 AM", 2),
            fallback = GuardianAlertText.fall(9.0, "11:51 AM", 2),
            location = EmergencyLocation(14.59788, 121.00245, 0, 15f),
        )

        assertTrue(body.length <= 160)
        assertTrue(body.all { it.code < 128 })
        assertTrue(body.contains("14.59788,121.00245"))
        assertFalse(body.contains("maps.google.com"))
    }

    @Test
    fun longModelWordingFallsBackToSinglePartAlert() {
        val fallback = GuardianAlertText.fall(9.0, "11:51 AM", 2)
        val body = GuardianAlertText.singlePart(
            body = "BANTAY ALERT: " + "Please check on me immediately. ".repeat(8),
            fallback = fallback,
            location = EmergencyLocation(14.59788, 121.00245, 0, 15f),
        )

        assertEquals(fallback + " " + EmergencyLocation(14.59788, 121.00245, 0, 15f).toSmsSuffix(), body)
        assertTrue(body.length <= 160)
    }
}
