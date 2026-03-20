package com.claudecraft;

import com.claudecraft.config.ClaudeCraftConfig;
import com.mojang.brigadier.CommandDispatcher;
import com.mojang.brigadier.arguments.StringArgumentType;
import net.minecraft.commands.CommandSourceStack;
import net.minecraft.commands.Commands;
import net.minecraft.network.chat.Component;
import net.minecraftforge.event.RegisterCommandsEvent;
import net.minecraftforge.eventbus.api.SubscribeEvent;
import net.minecraftforge.fml.common.Mod;

@Mod.EventBusSubscriber(modid = ClaudeCraft.MOD_ID)
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
                            boolean configured = ClaudeCraftConfig.isConfigured();
                            String model = ClaudeCraftConfig.MODEL.get();
                            int maxTokens = ClaudeCraftConfig.MAX_TOKENS.get();
                            ctx.getSource().sendSuccess(
                                    () -> Component.literal(String.format(
                                            "ClaudeCraft Status:\n  API Key: %s\n  Model: %s\n  Max Tokens: %d",
                                            configured ? "configured" : "NOT SET",
                                            model, maxTokens)),
                                    false);
                            return 1;
                        })));
    }
}
