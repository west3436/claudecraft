package com.claudecraft;

import com.claudecraft.api.ClaudeAPI;
import com.claudecraft.channel.ChannelProcessManager;
import com.claudecraft.config.ClaudeCraftConfig;
import dan200.computercraft.api.ComputerCraftAPI;
import net.minecraftforge.common.MinecraftForge;
import net.minecraftforge.eventbus.api.IEventBus;
import net.minecraftforge.eventbus.api.SubscribeEvent;
import net.minecraftforge.fml.ModLoadingContext;
import net.minecraftforge.fml.common.Mod;
import net.minecraftforge.fml.config.ModConfig;
import net.minecraftforge.fml.event.lifecycle.FMLCommonSetupEvent;
import net.minecraftforge.fml.event.server.FMLServerStoppingEvent;
import net.minecraftforge.fml.javafmlmod.FMLJavaModLoadingContext;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

@Mod(ClaudeCraft.MOD_ID)
public class ClaudeCraft {
    public static final String MOD_ID = "claudecraft";
    public static final Logger LOGGER = LogManager.getLogger(MOD_ID);

    public ClaudeCraft() {
        IEventBus modBus = FMLJavaModLoadingContext.get().getModEventBus();

        // Register config
        ModLoadingContext.get().registerConfig(ModConfig.Type.SERVER, ClaudeCraftConfig.SPEC);

        // Common setup
        modBus.addListener(this::commonSetup);

        // Register event handlers
        MinecraftForge.EVENT_BUS.register(this);
    }

    private void commonSetup(final FMLCommonSetupEvent event) {
        // Register the 'claude' Lua API on all CC:Tweaked computers
        ComputerCraftAPI.registerAPIFactory(ClaudeAPI::new);
        LOGGER.info("ClaudeCraft initialized - Claude API available on all computers");
    }

    @SubscribeEvent
    public void onServerStopping(FMLServerStoppingEvent event) {
        // Kill all Claude Code channel processes
        ChannelProcessManager.getInstance().shutdownAll();
    }
}
