package com.example.apdu_pos

import android.content.Context
import android.os.Build
import android.telephony.IccOpenLogicalChannelResponse
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges Flutter to Android TelephonyManager UICC APDU APIs.
 *
 * These calls require one of:
 *  - Carrier Privileges (the SIM/eSIM profile has an ARA-M rule containing
 *    the SHA-256 of this APK's signing certificate)
 *  - MODIFY_PHONE_STATE (signature|privileged) — only granted to platform-
 *    signed apps or privileged system apps
 *
 * A normal debug build that satisfies neither will receive SecurityException
 * from openLogicalChannel / transmitApdu / closeLogicalChannel. The UI
 * surfaces those errors verbatim so you can verify the wiring.
 */
class MainActivity : FlutterActivity() {

    private val channelName = "apdu_pos/telephony"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "hasCarrierPrivileges" -> {
                            val slot = call.argument<Int>("slot") ?: 0
                            result.success(tmForSlot(slot).hasCarrierPrivileges())
                        }
                        "openLogicalChannel" -> {
                            val slot = call.argument<Int>("slot") ?: 0
                            val aid = call.argument<String>("aid")
                                ?: return@setMethodCallHandler result.error(
                                    "ARG", "aid is required", null)
                            val p2 = call.argument<Int>("p2") ?: 0
                            result.success(openLogicalChannel(slot, aid, p2))
                        }
                        "transmitApdu" -> {
                            val slot = call.argument<Int>("slot") ?: 0
                            val channel = call.argument<Int>("channel")
                                ?: return@setMethodCallHandler result.error(
                                    "ARG", "channel is required", null)
                            val cla = call.argument<Int>("cla") ?: 0
                            val ins = call.argument<Int>("ins") ?: 0
                            val p1 = call.argument<Int>("p1") ?: 0
                            val p2 = call.argument<Int>("p2") ?: 0
                            val p3 = call.argument<Int>("p3") ?: 0
                            val data = call.argument<String>("data") ?: ""
                            result.success(
                                tmForSlot(slot).iccTransmitApduLogicalChannel(
                                    channel, cla, ins, p1, p2, p3, data))
                        }
                        "closeLogicalChannel" -> {
                            val slot = call.argument<Int>("slot") ?: 0
                            val channel = call.argument<Int>("channel")
                                ?: return@setMethodCallHandler result.error(
                                    "ARG", "channel is required", null)
                            // Public API returns void on older versions and
                            // boolean on newer ones; wrap in try/catch.
                            tmForSlot(slot).iccCloseLogicalChannel(channel)
                            result.success(true)
                        }
                        "listSlots" -> result.success(listSlots())
                        else -> result.notImplemented()
                    }
                } catch (e: SecurityException) {
                    result.error("SECURITY", e.message ?: "SecurityException", null)
                } catch (e: IllegalArgumentException) {
                    result.error("ARG", e.message ?: "IllegalArgumentException", null)
                } catch (e: IllegalStateException) {
                    result.error("STATE", e.message ?: "IllegalStateException", null)
                } catch (e: Exception) {
                    result.error("ERROR", "${e.javaClass.simpleName}: ${e.message}", null)
                }
            }
    }

    /** Resolve a TelephonyManager bound to the subscription on the given slot. */
    private fun tmForSlot(slot: Int): TelephonyManager {
        val baseTm = getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
        return try {
            val sm = getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE)
                    as SubscriptionManager
            val info = sm.getActiveSubscriptionInfoForSimSlotIndex(slot)
            if (info != null) baseTm.createForSubscriptionId(info.subscriptionId)
            else baseTm
        } catch (e: SecurityException) {
            // READ_PHONE_STATE not granted yet — fall back to default subscription.
            baseTm
        }
    }

    private fun openLogicalChannel(slot: Int, aid: String, p2: Int): Map<String, Any?> {
        val tm = tmForSlot(slot)
        val response: IccOpenLogicalChannelResponse? =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                tm.iccOpenLogicalChannel(aid, p2)
            } else {
                @Suppress("DEPRECATION")
                tm.iccOpenLogicalChannel(aid)
            }
        if (response == null) {
            return mapOf(
                "status" to -1,
                "channel" to -1,
                "selectResponse" to "",
                "error" to "null IccOpenLogicalChannelResponse"
            )
        }
        return mapOf(
            "status" to response.status,
            "channel" to response.channel,
            "selectResponse" to (response.selectResponse?.toHex() ?: "")
        )
    }

    private fun listSlots(): List<Map<String, Any?>> {
        val sm = getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE)
                as SubscriptionManager
        return try {
            val infos = sm.activeSubscriptionInfoList ?: emptyList()
            infos.map {
                mapOf(
                    "slotIndex" to it.simSlotIndex,
                    "subscriptionId" to it.subscriptionId,
                    "carrierName" to (it.carrierName?.toString() ?: ""),
                    "displayName" to (it.displayName?.toString() ?: "")
                )
            }
        } catch (e: SecurityException) {
            emptyList()
        }
    }

    private fun ByteArray.toHex(): String =
        joinToString("") { "%02X".format(it) }
}
