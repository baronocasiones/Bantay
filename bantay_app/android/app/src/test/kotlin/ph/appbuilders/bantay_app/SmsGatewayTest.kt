package ph.appbuilders.bantay_app

import org.junit.Assert.assertEquals
import org.junit.Test

class SmsGatewayTest {
    @Test fun networkFailureHasReadableStableCode() {
        assertEquals("network_error", smsErrorForResultCode(17, 1, 4, 17))
    }

    @Test fun unknownFailureKeepsRawCodeForDiagnosis() {
        assertEquals("sms_error_999", smsErrorForResultCode(999, 1, 4, 17))
    }
}
