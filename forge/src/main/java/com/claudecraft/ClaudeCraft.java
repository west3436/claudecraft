package com.claudecraft;

import com.claudecraft.api.ClaudeAPI;
import com.claudecraft.config.ClaudeCraftConfig;
import dan200.computercraft.api.ComputerCraftAPI;
import net.minecraftforge.common.MinecraftForge;
import net.minecraftforge.fml.ModLoadingContext;
import net.minecraftforge.fml.common.Mod;
import net.minecraftforge.fml.config.ModConfig;
import net.minecraftforge.fml.event.lifecycle.FMLCommonSetupEvent;
import net.minecraftforge.fml.javafmlmod.FMLJavaModLoadingContext;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

@Mod(ClaudeCraft.MOD_ID)
public class ClaudeCraft {
    public static final String MOD_ID = "claudecraft";
    public static final Logger LOGGER = LoggerFactory.getLogger(MOD_ID);

    public ClaudeCraft() {
        var modBus = FMLJavaModLoadingContext.get().getModEventBus();

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
}
