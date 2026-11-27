package com.claudecraft;

import com.claudecraft.channel.ChannelProcessManager;
import com.claudecraft.config.ApiKeyProvider;
import com.claudecraft.config.ClaudeCraftConfig;
import com.mojang.brigadier.CommandDispatcher;
import com.mojang.brigadier.arguments.StringArgumentType;
import net.minecraft.commands.CommandSourceStack;
import net.minecraft.commands.Commands;
import net.minecraft.network.chat.Component;
import net.neoforged.bus.api.SubscribeEvent;
import net.neoforged.fml.common.EventBusSubscriber;
import net.neoforged.neoforge.event.RegisterCommandsEvent;

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
                                    String key = StringArgumentType.getString(ctx, "key").trim();
                                    if (!ApiKeyProvider.isValidFormat(key)) {
                                        ctx.getSource().sendFailure(
                                                Component.literal("Invalid API key. Must start with sk-"));
                                        return 0;
                                    }
                                    try {
                                        ApiKeyProvider.store(key);
                                    } catch (Exception e) {
                                        ctx.getSource().sendFailure(Component.literal(
                                                "Could not save the API key: " + e.getMessage()));
                                        ClaudeCraft.LOGGER.error("Failed to write {}",
                                                ApiKeyProvider.secretsFileDisplay(), e);
                                        return 0;
                                    }
                                    String msg = "API key saved to " + ApiKeyProvider.secretsFileDisplay()
                                            + " (server only, never sent to clients).";
                                    if (ApiKeyProvider.isEnvironmentKeySet()) {
                                        msg += " Note: " + ApiKeyProvider.ENV_VAR
                                                + " is set and takes precedence over the file.";
                                    }
                                    String reply = msg;
                                    ctx.getSource().sendSuccess(() -> Component.literal(reply), false);
                                    ClaudeCraft.LOGGER.info("ClaudeCraft API key updated by {}",
                                            ctx.getSource().getTextName());
                                    return 1;
                                })))
                .then(Commands.literal("clearkey")
                        .executes(ctx -> {
                            boolean deleted;
                            try {
                                deleted = ApiKeyProvider.clear();
                            } catch (Exception e) {
                                ctx.getSource().sendFailure(Component.literal(
                                        "Could not delete the API key file: " + e.getMessage()));
                                ClaudeCraft.LOGGER.error("Failed to delete {}",
                                        ApiKeyProvider.secretsFileDisplay(), e);
                                return 0;
                            }
                            String msg = deleted
                                    ? "API key file " + ApiKeyProvider.secretsFileDisplay() + " deleted."
                                    : "No API key file to delete.";
                            if (ApiKeyProvider.isEnvironmentKeySet()) {
                                msg += " " + ApiKeyProvider.ENV_VAR
                                        + " is still set, so a key is still active. Unset it and restart to remove it.";
                            }
                            String reply = msg;
                            ctx.getSource().sendSuccess(() -> Component.literal(reply), false);
                            ClaudeCraft.LOGGER.info("ClaudeCraft API key file cleared by {}",
                                    ctx.getSource().getTextName());
                            return 1;
                        }))
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
                            String model = ClaudeCraftConfig.MODEL.get();
                            int maxTokens = ClaudeCraftConfig.MAX_TOKENS.get();

                            StringBuilder sb = new StringBuilder();
                            sb.append("ClaudeCraft Status:\n");
                            sb.append("  API Key: ").append(describeApiKey()).append("\n");
                            sb.append("  Model: ").append(model).append("\n");
                            sb.append("  Max Tokens: ").append(maxTokens);

                            String status = sb.toString();
                            ctx.getSource().sendSuccess(
                                    () -> Component.literal(status), false);
                            return 1;
                        })));
    }

    /** Whether a key is set and where it comes from. Never includes the key itself. */
    private static String describeApiKey() {
        ApiKeyProvider.Source source = ApiKeyProvider.source();
        if (source == ApiKeyProvider.Source.NONE) return "NOT SET";
        String where = source == ApiKeyProvider.Source.FILE
                ? source.description() + " " + ApiKeyProvider.secretsFileDisplay()
                : source.description();
        return (ApiKeyProvider.isConfigured() ? "configured" : "INVALID (must start with sk-)")
                + " (from " + where + ")";
    }
}
