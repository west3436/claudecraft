package com.claudecraft;

import com.claudecraft.channel.ChannelAccess;
import com.claudecraft.channel.ChannelProcessManager;
import com.claudecraft.config.ClaudeCraftConfig;
import com.mojang.brigadier.CommandDispatcher;
import com.mojang.brigadier.arguments.IntegerArgumentType;
import com.mojang.brigadier.arguments.StringArgumentType;
import com.mojang.brigadier.builder.LiteralArgumentBuilder;
import net.minecraft.commands.CommandSourceStack;
import net.minecraft.commands.Commands;
import net.minecraft.network.chat.Component;
import net.neoforged.bus.api.SubscribeEvent;
import net.neoforged.fml.common.EventBusSubscriber;
import net.neoforged.neoforge.event.RegisterCommandsEvent;

import java.util.List;
import java.util.stream.Collectors;

@EventBusSubscriber(modid = ClaudeCraft.MOD_ID)
public class ClaudeCraftCommand {

    @SubscribeEvent
    public static void onRegisterCommands(RegisterCommandsEvent event) {
        CommandDispatcher<CommandSourceStack> dispatcher = event.getDispatcher();

        dispatcher.register(Commands.literal("claudecraft")
                .requires(source -> source.hasPermission(3)) // OP level 3+
                .then(Commands.literal("setkey")
                        .then(Commands.argument("key", StringArgumentType.string())
                                .executes(ctx -> {
                                    String key = StringArgumentType.getString(ctx, "key");
                                    if (!key.startsWith("sk-")) {
                                        ctx.getSource().sendFailure(
                                                Component.literal("Invalid API key. Must start with sk-"));
                                        return 0;
                                    }
                                    ClaudeCraftConfig.API_KEY.set(key);
                                    ClaudeCraftConfig.API_KEY.save();
                                    ctx.getSource().sendSuccess(
                                            () -> Component.literal("API key set successfully. ClaudeCraft is ready."),
                                            false);
                                    ClaudeCraft.LOGGER.info("ClaudeCraft API key updated by {}",
                                            ctx.getSource().getTextName());
                                    return 1;
                                })))
                .then(Commands.literal("model")
                        .then(Commands.argument("model", StringArgumentType.string())
                                .executes(ctx -> {
                                    String model = StringArgumentType.getString(ctx, "model");
                                    ClaudeCraftConfig.MODEL.set(model);
                                    ClaudeCraftConfig.MODEL.save();
                                    ctx.getSource().sendSuccess(
                                            () -> Component.literal("Model set to: " + model), false);
                                    return 1;
                                })))
                .then(Commands.literal("status")
                        .executes(ctx -> {
                            boolean apiKeySet = ClaudeCraftConfig.isApiKeyConfigured();
                            String model = ClaudeCraftConfig.MODEL.get();
                            int maxTokens = ClaudeCraftConfig.MAX_TOKENS.get();

                            StringBuilder sb = new StringBuilder();
                            sb.append("ClaudeCraft Status:\n");
                            sb.append("  API Key: ").append(
                                    apiKeySet ? "configured" : "NOT SET").append("\n");
                            sb.append("  Model: ").append(model).append("\n");
                            sb.append("  Max Tokens: ").append(maxTokens).append("\n");
                            sb.append("  Channel mode: ").append(
                                    ClaudeCraftConfig.ENABLE_CHANNEL_MODE.get() ? "enabled" : "disabled")
                                    .append(" (").append(ChannelProcessManager.getInstance().listSessions().size())
                                    .append("/").append(ClaudeCraftConfig.MAX_CHANNEL_SESSIONS.get())
                                    .append(" sessions)");

                            String status = sb.toString();
                            ctx.getSource().sendSuccess(
                                    () -> Component.literal(status), false);
                            return 1;
                        }))
                .then(channelCommands()));
    }

    /**
     * /claudecraft channel enable|disable|allow|deny|list|sessions|kill.
     * Channel access is per computer ID: the mod can't tell who is typing at a computer.
     */
    private static LiteralArgumentBuilder<CommandSourceStack> channelCommands() {
        return Commands.literal("channel")
                .then(Commands.literal("enable")
                        .executes(ctx -> setChannelEnabled(ctx.getSource(), true)))
                .then(Commands.literal("disable")
                        .executes(ctx -> setChannelEnabled(ctx.getSource(), false)))
                .then(Commands.literal("allow")
                        .then(Commands.argument("computerId", IntegerArgumentType.integer(0))
                                .executes(ctx -> {
                                    int id = IntegerArgumentType.getInteger(ctx, "computerId");
                                    boolean added = ChannelAccess.allow(id);
                                    ClaudeCraft.LOGGER.info("Channel access for computer #{} granted by {}",
                                            id, ctx.getSource().getTextName());
                                    String msg = added
                                            ? "Computer #" + id + " may now use channel mode."
                                            : "Computer #" + id + " was already allowed.";
                                    ctx.getSource().sendSuccess(() -> Component.literal(msg), true);
                                    return 1;
                                })))
                .then(Commands.literal("deny")
                        .then(Commands.argument("computerId", IntegerArgumentType.integer(0))
                                .executes(ctx -> {
                                    int id = IntegerArgumentType.getInteger(ctx, "computerId");
                                    boolean removed = ChannelAccess.deny(id);
                                    boolean stopped = ChannelProcessManager.getInstance().stopSession(id);
                                    ClaudeCraft.LOGGER.info("Channel access for computer #{} revoked by {}",
                                            id, ctx.getSource().getTextName());
                                    String msg = (removed
                                            ? "Computer #" + id + " may no longer use channel mode."
                                            : "Computer #" + id + " was not on the allowlist.")
                                            + (stopped ? " Its session was stopped." : "");
                                    ctx.getSource().sendSuccess(() -> Component.literal(msg), true);
                                    return 1;
                                })))
                .then(Commands.literal("list")
                        .executes(ctx -> {
                            List<Integer> ids = ChannelAccess.allowedComputers();
                            StringBuilder sb = new StringBuilder("Channel mode: ");
                            sb.append(ClaudeCraftConfig.ENABLE_CHANNEL_MODE.get() ? "enabled" : "disabled");
                            sb.append(", max ").append(ClaudeCraftConfig.MAX_CHANNEL_SESSIONS.get())
                                    .append(" sessions\n");
                            if (ChannelAccess.singleplayerBypassActive()) {
                                sb.append("Singleplayer: every computer is allowed (allowAllInSingleplayer)\n");
                            }
                            sb.append("Allowed computers: ");
                            sb.append(ids.isEmpty() ? "none" : ids.stream()
                                    .map(i -> "#" + i).collect(Collectors.joining(", ")));
                            String msg = sb.toString();
                            ctx.getSource().sendSuccess(() -> Component.literal(msg), false);
                            return 1;
                        }))
                .then(Commands.literal("sessions")
                        .executes(ctx -> {
                            List<ChannelProcessManager.SessionInfo> sessions =
                                    ChannelProcessManager.getInstance().listSessions();
                            StringBuilder sb = new StringBuilder("Claude Code sessions: ")
                                    .append(sessions.size()).append("/")
                                    .append(ClaudeCraftConfig.MAX_CHANNEL_SESSIONS.get());
                            for (ChannelProcessManager.SessionInfo s : sessions) {
                                sb.append("\n  #").append(s.computerId)
                                        .append(": ").append(s.status())
                                        .append(", port ").append(s.port)
                                        .append(", pid ").append(s.pid())
                                        .append(", up ").append(formatUptime(s.uptimeSeconds()));
                            }
                            String msg = sb.toString();
                            ctx.getSource().sendSuccess(() -> Component.literal(msg), false);
                            return 1;
                        }))
                .then(Commands.literal("kill")
                        .then(Commands.argument("computerId", IntegerArgumentType.integer(0))
                                .executes(ctx -> {
                                    int id = IntegerArgumentType.getInteger(ctx, "computerId");
                                    if (!ChannelProcessManager.getInstance().stopSession(id)) {
                                        ctx.getSource().sendFailure(Component.literal(
                                                "Computer #" + id + " has no Claude Code session."));
                                        return 0;
                                    }
                                    ClaudeCraft.LOGGER.info("Channel session for computer #{} killed by {}",
                                            id, ctx.getSource().getTextName());
                                    ctx.getSource().sendSuccess(() -> Component.literal(
                                            "Stopped the Claude Code session for computer #" + id + "."), true);
                                    return 1;
                                })));
    }

    private static int setChannelEnabled(CommandSourceStack source, boolean enabled) {
        ChannelAccess.setEnabled(enabled);
        int stopped = 0;
        if (!enabled) {
            // stopSession doesn't block the server thread waiting for exits
            for (ChannelProcessManager.SessionInfo s : ChannelProcessManager.getInstance().listSessions()) {
                if (ChannelProcessManager.getInstance().stopSession(s)) stopped++;
            }
        }
        ClaudeCraft.LOGGER.info("Channel mode {} by {}", enabled ? "enabled" : "disabled",
                source.getTextName());
        String msg = enabled
                ? "Channel mode enabled. Allow computers with /claudecraft channel allow <computerId>."
                : "Channel mode disabled." + (stopped > 0 ? " Stopped " + stopped + " session(s)." : "");
        source.sendSuccess(() -> Component.literal(msg), true);
        return 1;
    }

    private static String formatUptime(long seconds) {
        if (seconds < 60) return seconds + "s";
        if (seconds < 3600) return (seconds / 60) + "m";
        return (seconds / 3600) + "h " + ((seconds % 3600) / 60) + "m";
    }
}
