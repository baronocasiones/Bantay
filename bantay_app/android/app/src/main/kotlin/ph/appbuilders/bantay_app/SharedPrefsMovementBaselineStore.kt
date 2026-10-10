package ph.appbuilders.bantay_app

import android.content.Context

/** Private on-device storage for the non-identifying movement variability profile. */
class SharedPrefsMovementBaselineStore(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(
        PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )

    fun load(): MovementBaselineSnapshot = MovementBaselineSnapshot(
        windows = preferences.getLong(KEY_WINDOWS, 0L),
        meanVariance = preferences.getFloat(KEY_MEAN, 0f).toDouble(),
        squaredDeviationTotal = preferences.getFloat(KEY_SQUARED_DEVIATION, 0f).toDouble(),
    )

    fun save(snapshot: MovementBaselineSnapshot) {
        preferences.edit()
            .putLong(KEY_WINDOWS, snapshot.windows)
            .putFloat(KEY_MEAN, snapshot.meanVariance.toFloat())
            .putFloat(KEY_SQUARED_DEVIATION, snapshot.squaredDeviationTotal.toFloat())
            .apply()
    }

    private companion object {
        const val PREFERENCES_NAME = "bantay_movement_profile"
        const val KEY_WINDOWS = "windows"
        const val KEY_MEAN = "mean_variance"
        const val KEY_SQUARED_DEVIATION = "squared_deviation_total"
    }
}
