package app.quietvpn.quiet_vpn

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.NetworkCapabilities as NC
import android.net.TelephonyNetworkSpecifier
import android.os.Build
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager

/** Active data subscription only. Never reads phone numbers, IMSI, IMEI or cell IDs. */
object MobileNetwork {
    data class Info(val subscription: Int, val operator: String?, val name: String?,
        val simOperator: String?, val simName: String?, val source: String,
        val radio: Int? = null, val signal: Int? = null) {
        val identity: String get() = "$subscription|${operator ?: "?"}|${simOperator ?: "?"}"
    }
    fun chooseSubscription(networkSub: Int?, activeSub: Int, defaultSub: Int, modern: Boolean): Int? {
        // On modern Android an absent active data SIM is not the default voice/data SIM.
        val chosen = networkSub ?: if (modern) activeSub else defaultSub
        return chosen.takeIf { SubscriptionManager.isValidSubscriptionId(it) }
    }
    private fun code(value: String?): String? = value?.takeIf { it.matches(Regex("[0-9]{5,6}")) }
    private fun name(value: String?): String? = value?.filter { !it.isISOControl() }?.trim()?.take(64)?.takeIf { it.isNotEmpty() }
    fun read(context: Context, caps: NC, extended: Boolean = false): Info? {
        if (!caps.hasTransport(NC.TRANSPORT_CELLULAR) || caps.hasTransport(NC.TRANSPORT_WIFI)) return null
        return try {
            val modern = Build.VERSION.SDK_INT >= 30
            val networkSub = if (modern) (caps.networkSpecifier as? TelephonyNetworkSpecifier)
                ?.subscriptionId?.takeIf { SubscriptionManager.isValidSubscriptionId(it) } else null
            val active = if (modern) SubscriptionManager.getActiveDataSubscriptionId() else -1
            val fallback = if (!modern) SubscriptionManager.getDefaultDataSubscriptionId() else -1
            val sub = chooseSubscription(networkSub, active, fallback, modern) ?: return null
            val tm = context.getSystemService(TelephonyManager::class.java)?.createForSubscriptionId(sub) ?: return null
            // Basic operator metadata does not depend on the optional signal/radio permission.
            val operator = try { code(tm.networkOperator) } catch (_: Exception) { null }
            val operatorName = try { name(tm.networkOperatorName) } catch (_: Exception) { null }
            val sim = try { code(tm.simOperator) } catch (_: Exception) { null }
            val simName = try { name(tm.simOperatorName) } catch (_: Exception) { null }
            var radio: Int? = null
            var signal: Int? = null
            if (extended && context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED) {
                radio = try { tm.dataNetworkType.takeIf { it != TelephonyManager.NETWORK_TYPE_UNKNOWN } } catch (_: Exception) { null }
                if (Build.VERSION.SDK_INT >= 28) signal = try { tm.signalStrength?.level } catch (_: Exception) { null }
            }
            // Discard an observation taken across a SIM handover.
            if (networkSub == null && sub != if (modern) SubscriptionManager.getActiveDataSubscriptionId()
                else SubscriptionManager.getDefaultDataSubscriptionId()) return null
            Info(sub, operator, operatorName, sim, simName,
                if (networkSub != null) "network" else if (modern) "active-data" else "default-data", radio, signal)
        } catch (_: Exception) { null }
    }
}
