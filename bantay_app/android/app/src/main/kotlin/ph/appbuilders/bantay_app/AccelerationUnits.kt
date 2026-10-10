package ph.appbuilders.bantay_app

/** Android SensorEvent accelerometer axes are m/s²; cascade axes are g. */
object AccelerationUnits {
    private const val MS2_PER_G = 9.80665
    fun toG(valueMs2: Double): Double = valueMs2 / MS2_PER_G
}
