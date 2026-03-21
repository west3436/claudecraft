package com.claudecraft;

import com.claudecraft.config.ClaudeCraftConfig;
import com.mojang.brigadier.CommandDispatcher;
import com.mojang.brigadier.arguments.StringArgumentType;
import net.minecraft.command.CommandSource;
import net.minecraft.command.Commands;
import net.minecraft.util.text.StringTextComponent;
import net.minecraftforge.event.RegisterCommandsEvent;
import net.minecraftforge.eventbus.api.SubscribeEvent;
import net.minecraftforge.fml.common.Mod;

@Mod.EventBusSubscriber(modid = ClaudeCraft.MOD_ID)
public class ClaudeCraftCommand {

    @SubscribeEvent
    public static void onRegisterCommands(RegisterCommandsEvent event) {
        CommandDispatcher<CommandSource> dispatcher = event.getDispatcher();

        dispatcher.register(Commands.literal("claudecraft")
                .requires(source -> source.hasPermission(3)) // OP level 3+
                .then(Commands.literal("setkey")
                        .then(Commands.argument("key", StringArgumentType.string())
                                .executes(ctx -> {
                                    String key = StringArgumentType.getString(ctx, "key");
                                    if (!key.startsWith("sk-")) {
                                        ctx.getSource().sendFailure(
                                                new StringTextComponent("Invalid API key. Must start with sk-"));
                                        return 0;
                                    }
                                    ClaudeCraftConfig.API_KEY.set(key);
                                    ClaudeCraftConfig.API_KEY.save();
                                    ctx.getSource().sendSuccess(
                                            new StringTextComponent("API key set successfully. ClaudeCraft is ready."),
                                            false);
                                    ClaudeCraft.LOGGER.info("ClaudeCraft API key updated by {}",
                                            ctx.getSource().getDisplayName().getString());
                                    return 1;
                                })))
                .then(Commands.literal("model")
                        .then(Commands.argument("model", StringArgumentType.string())
                                .executes(ctx -> {
                                    String model = StringArgumentType.getString(ctx, "model");
                                    ClaudeCraftConfig.MODEL.set(model);
                                    ClaudeCraftConfig.MODEL.save();
                                    ctx.getSource().sendSuccess(
                                            new StringTextComponent("Model set to: " + model), false);
                                    return 1;
                                })))
                .then(Commands.literal("status")
                        .executes(ctx -> {
                            boolean apiKeySet = ClaudeCraftConfig.isApiKeyConfigured();
                            String model = ClaudeCraftConfig.MODEL.get();
                            int maxTokens = ClaudeCraftConfig.MAX_TOKENS.get();
                            ctx.getSource().sendSuccess(
                                    new StringTextComponent(String.format(
                                            "ClaudeCraft Status:\n  API Key: %s\n  Model: %s\n  Max Tokens: %d\n  Channel mode: available (per-computer)",
                                            apiKeySet ? "configured" : "NOT SET",
                                            model, maxTokens)),
                                    false);
                            return 1;
                        })));
    }
}
