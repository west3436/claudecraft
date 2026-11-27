package com.claudecraft.channel;

import com.claudecraft.config.ClaudeCraftConfig;
import net.minecraft.server.MinecraftServer;
import net.neoforged.neoforge.server.ServerLifecycleHooks;

import java.util.ArrayList;
import java.util.List;
import java.util.TreeSet;

/**
 * Decides which computers may use channel mode.
 *
 * <p>The mod can't tell which player is typing at a computer, so access is
 * granted per computer: channel mode must be enabled, and the computer's ID
 * must be on the operator-managed allowlist (or the singleplayer convenience
 * option applies). The session cap is enforced by {@link ChannelProcessManager}.
 */
public final class ChannelAccess {
    private ChannelAccess() {}

    /**
     * Why a computer may not use channel mode right now, or null if it may.
     * The message is shown on the computer's terminal.
     */
    public static String refusalFor(int computerId) {
        if (!ClaudeCraftConfig.ENABLE_CHANNEL_MODE.get()) {
            return "Channel mode is disabled on this server. "
                    + "An operator can enable it with /claudecraft channel enable";
        }
        if (isAllowed(computerId) || singleplayerBypassActive()) {
            return null;
        }
        return "Computer #" + computerId + " is not allowed to use channel mode. "
                + "An operator can run /claudecraft channel allow " + computerId;
    }

    public static boolean isAllowed(int computerId) {
        for (Number id : ClaudeCraftConfig.ALLOWED_COMPUTERS.get()) {
            if (id.intValue() == computerId) return true;
        }
        return false;
    }

    /**
     * True when allowAllInSingleplayer is on and this is a singleplayer world
     * that is not open to LAN.
     */
    public static boolean singleplayerBypassActive() {
        if (!ClaudeCraftConfig.ALLOW_ALL_IN_SINGLEPLAYER.get()) return false;
        MinecraftServer server = ServerLifecycleHooks.getCurrentServer();
        return server != null && server.isSingleplayer() && !server.isPublished();
    }

    /** The allowlist, sorted. */
    public static List<Integer> allowedComputers() {
        TreeSet<Integer> ids = new TreeSet<>();
        for (Number id : ClaudeCraftConfig.ALLOWED_COMPUTERS.get()) ids.add(id.intValue());
        return new ArrayList<>(ids);
    }

    /** Add a computer to the allowlist and save the config. Returns false if it was already there. */
    public static boolean allow(int computerId) {
        TreeSet<Integer> ids = new TreeSet<>(allowedComputers());
        if (!ids.add(computerId)) return false;
        save(ids);
        return true;
    }

    /** Remove a computer from the allowlist and save the config. Returns false if it wasn't there. */
    public static boolean deny(int computerId) {
        TreeSet<Integer> ids = new TreeSet<>(allowedComputers());
        if (!ids.remove(computerId)) return false;
        save(ids);
        return true;
    }

    public static void setEnabled(boolean enabled) {
        ClaudeCraftConfig.ENABLE_CHANNEL_MODE.set(enabled);
        ClaudeCraftConfig.ENABLE_CHANNEL_MODE.save();
    }

    private static void save(TreeSet<Integer> ids) {
        ClaudeCraftConfig.ALLOWED_COMPUTERS.set(new ArrayList<>(ids));
        ClaudeCraftConfig.ALLOWED_COMPUTERS.save();
    }
}
