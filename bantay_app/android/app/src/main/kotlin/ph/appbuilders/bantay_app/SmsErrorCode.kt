package ph.appbuilders.bantay_app

/** Android-free mapping so carrier failures have stable, user-readable codes. */
internal fun smsErrorForResultCode(
    resultCode: Int,
    radioOffCode: Int,
    noServiceCode: Int,
    networkErrorCode: Int,
): String = when (resultCode) {
    radioOffCode -> "radio_off"
    noServiceCode -> "no_service"
    networkErrorCode -> "network_error"
    else -> "sms_error_$resultCode"
}
