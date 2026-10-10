package ph.appbuilders.bantay_app

import org.junit.Assert.assertEquals
import org.junit.Test

class AccelerationUnitsTest {
    @Test fun restingAndroidAccelerometerConvertsToOneG() {
        assertEquals(1.0, AccelerationUnits.toG(9.80665), 0.000001)
    }
}
