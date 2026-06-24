package com.claudecraft;

import com.claudecraft.api.ClaudeAPI;
import com.claudecraft.channel.ChannelProcessManager;
import com.claudecraft.config.ClaudeCraftConfig;
import dan200.computercraft.api.ComputerCraftAPI;
import net.neoforged.bus.api.IEventBus;
import net.neoforged.bus.api.SubscribeEvent;
import net.neoforged.fml.ModContainer;
import net.neoforged.fml.common.Mod;
import net.neoforged.fml.config.ModConfig;
import net.neoforged.fml.event.lifecycle.FMLCommonSetupEvent;
import net.neoforged.neoforge.common.NeoForge;
import net.neoforged.neoforge.event.server.ServerStoppingEvent;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

@Mod(ClaudeCraft.MOD_ID)
public class ClaudeCraft {
    public static final String MOD_ID = "claudecraft";
    public static final Logger LOGGER = LoggerFactory.getLogger(MOD_ID);

    public ClaudeCraft(IEventBus modBus, ModContainer modContainer) {
        // Register config
        modContainer.registerConfig(ModConfig.Type.SERVER, ClaudeCraftConfig.SPEC);

        // Common setup
        modBus.addListener(this::commonSetup);

        // Register event handlers
        NeoForge.EVENT_BUS.register(this);
    }

    private void commonSetup(final FMLCommonSetupEvent event) {
        // Register the 'claude' Lua API on all CC:Tweaked computers
        ComputerCraftAPI.registerAPIFactory(ClaudeAPI::new);
        LOGGER.info("ClaudeCraft initialized - Claude API available on all computers");
    }

    @SubscribeEvent
    public void onServerStopping(ServerStoppingEvent event) {
        // Kill all Claude Code channel processes
        ChannelProcessManager.getInstance().shutdownAll();
    }
}
