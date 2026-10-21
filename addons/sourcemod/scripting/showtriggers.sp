/*
 * sm-showtriggers: lets players see the map's trigger brushes.
 * Copyright (C) 2026 catmint
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or (at your
 * option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License
 * for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define FSOLID_TRIGGER 0x0008
#define EF_NODRAW      0x0020
#define SOLID_BSP      1
#define SOLID_VPHYSICS 6
#define TRANSMIT_BITS  (FL_EDICT_ALWAYS | FL_EDICT_DONTSEND | \
                        FL_EDICT_PVSCHECK)
#define ALPHA_MASK     0xFF000000 // m_clrRender is RGBA from the low byte

#if !defined PLUGIN_VERSION
#define PLUGIN_VERSION "dev"
#endif

public Plugin myinfo = {
    name = "Show Triggers",
    author = "catmint",
    description = "Lets players see the map's trigger brushes",
    version = PLUGIN_VERSION,
    url = "https://github.com/misscatmint/sm-showtriggers/"
};

bool g_bShowing[MAXPLAYERS + 1];
int g_iViewers;
ArrayList g_hShown;    // trigger reference, saved m_clrRender
ArrayList g_hStandIns; // stand-in reference, trigger reference

public void OnPluginStart() {
    g_hShown = new ArrayList(2);
    g_hStandIns = new ArrayList(2);
    RegConsoleCmd("sm_showtriggers", Command_ShowTriggers,
                  "Toggles showing trigger brushes for you");
}

public void OnPluginEnd() {
    if (g_iViewers > 0)
        Deactivate();
}

public void OnMapEnd() {
    for (int client = 1; client <= MaxClients; ++client) {
        if (g_bShowing[client])
            SetShowing(client, false);
    }
}

public void OnClientDisconnect(int client) {
    if (g_bShowing[client])
        SetShowing(client, false);
}

Action Command_ShowTriggers(int client, int args) {
    if (client == 0) {
        ReplyToCommand(client, "sm_showtriggers can only be used by players.");
        return Plugin_Handled;
    }

    SetShowing(client, !g_bShowing[client]);
    PrintToChat(client, (g_bShowing[client]
                            ? "Showing trigger brushes."
                            : "Stopped showing trigger brushes."));
    return Plugin_Handled;
}

void SetShowing(int client, bool show) {
    g_bShowing[client] = show;
    g_iViewers += show ? 1 : -1;
    if (show && g_iViewers == 1)
        Activate();
    else if (!show && g_iViewers == 0)
        Deactivate();
}

void Activate() {
    int maxEntities = GetMaxEntities();
    for (int entity = MaxClients + 1; entity < maxEntities; ++entity) {
        if (IsValidEdict(entity))
            ShowIfTrigger(entity);
    }
}

void Deactivate() {
    for (int i = 0; i < g_hShown.Length; ++i) {
        int entity = EntRefToEntIndex(g_hShown.Get(i));
        if (entity != INVALID_ENT_REFERENCE)
            Hide(entity, g_hShown.Get(i, 1));
    }
    g_hShown.Clear();

    for (int i = 0; i < g_hStandIns.Length; ++i) {
        int standIn = EntRefToEntIndex(g_hStandIns.Get(i));
        if (standIn != INVALID_ENT_REFERENCE)
            RemoveEntity(standIn);
    }
    g_hStandIns.Clear();
}

public void OnEntityCreated(int entity, const char[] classname) {
    if (g_iViewers == 0 || entity <= MaxClients || entity >= GetMaxEntities())
        return;

    // Solid flags and the model are only set during spawn.
    SDKHook(entity, SDKHook_SpawnPost, OnTriggerSpawnPost);
}

void OnTriggerSpawnPost(int entity) {
    SDKUnhook(entity, SDKHook_SpawnPost, OnTriggerSpawnPost);
    if (g_iViewers > 0 && IsValidEdict(entity))
        ShowIfTrigger(entity);
}

public void OnEntityDestroyed(int entity) {
    if (g_iViewers == 0 || entity <= MaxClients)
        return;

    // Round restarts keep func_illusionary but rebuild most triggers.
    int index = g_hStandIns.FindValue(EntIndexToEntRef(entity), 1);
    if (index == -1)
        return;

    int standIn = EntRefToEntIndex(g_hStandIns.Get(index));
    if (standIn != INVALID_ENT_REFERENCE)
        RemoveEntity(standIn);
    g_hStandIns.Erase(index);
}

void ShowIfTrigger(int entity) {
    if (!IsHiddenTrigger(entity))
        return;

    // Filtering a trigger clients already get would break it for others.
    if (GetEdictFlags(entity) & FL_EDICT_DONTSEND)
        Show(entity);
    else
        AddStandIn(entity);
}

bool IsHiddenTrigger(int entity) {
    if (!HasEntProp(entity, Prop_Send, "m_usSolidFlags"))
        return false;

    // Disabled triggers drop FSOLID_TRIGGER but keep CBaseTrigger's fields.
    if (!(GetEntProp(entity, Prop_Send, "m_usSolidFlags") & FSOLID_TRIGGER) &&
        !HasEntProp(entity, Prop_Data, "m_hTouchingEntities")) {
        return false;
    }

    // Box solids don't collide with their model, so it's the wrong shape.
    int solidType = GetEntProp(entity, Prop_Send, "m_nSolidType");
    if (solidType != SOLID_BSP && solidType != SOLID_VPHYSICS)
        return false;

    if (!(GetEntProp(entity, Prop_Send, "m_fEffects") & EF_NODRAW))
        return false;

    char model[2];
    GetEntPropString(entity, Prop_Data, "m_ModelName", model, sizeof(model));
    return model[0] == '*';
}

void Show(int entity) {
    SetEntProp(entity, Prop_Send, "m_fEffects",
               GetEntProp(entity, Prop_Send, "m_fEffects") & ~EF_NODRAW);
    // A raw m_fEffects write skips the recompute RemoveEffects would do.
    SetEdictFlags(entity, ((GetEdictFlags(entity) & ~TRANSMIT_BITS) |
                           FL_EDICT_PVSCHECK |
                           FL_EDICT_DIRTY_PVS_INFORMATION));
    int color = GetEntProp(entity, Prop_Send, "m_clrRender");
    SetEntProp(entity, Prop_Send, "m_clrRender", color & ALPHA_MASK);
    SDKHook(entity, SDKHook_SetTransmit, OnTriggerTransmit);
    int index = g_hShown.Push(EntIndexToEntRef(entity));
    g_hShown.Set(index, color, 1);
}

void Hide(int entity, int color) {
    SDKUnhook(entity, SDKHook_SetTransmit, OnTriggerTransmit);
    SetEntProp(entity, Prop_Send, "m_clrRender", color);
    // Shown triggers had both flags; the engine keeps a parent networked.
    SetEntProp(entity, Prop_Send, "m_fEffects",
               GetEntProp(entity, Prop_Send, "m_fEffects") | EF_NODRAW);
    int transmit = GetEntPropEnt(entity, Prop_Data, "m_hMoveChild") == -1
                       ? FL_EDICT_DONTSEND
                       : FL_EDICT_PVSCHECK;
    SetEdictFlags(entity, (GetEdictFlags(entity) & ~TRANSMIT_BITS) | transmit);
}

void AddStandIn(int trigger) {
    int standIn = CreateEntityByName("func_illusionary");
    if (standIn == -1)
        return;

    char model[16];
    GetEntPropString(trigger, Prop_Data, "m_ModelName", model, sizeof(model));
    float origin[3], angles[3];
    GetEntPropVector(trigger, Prop_Data, "m_vecAbsOrigin", origin);
    GetEntPropVector(trigger, Prop_Data, "m_angAbsRotation", angles);
    DispatchKeyValue(standIn, "model", model);
    DispatchKeyValueVector(standIn, "origin", origin);
    DispatchSpawn(standIn);
    ActivateEntity(standIn);
    // Spawn zeroes the angles.
    TeleportEntity(standIn, NULL_VECTOR, angles, NULL_VECTOR);
    SetEntProp(standIn, Prop_Send, "m_clrRender",
               GetEntProp(standIn, Prop_Send, "m_clrRender") & ALPHA_MASK);
    // A child keeps its parent networked, harmless since this one already is.
    if (GetEntPropEnt(trigger, Prop_Data, "m_hMoveParent") != -1) {
        SetVariantString("!activator");
        AcceptEntityInput(standIn, "SetParent", trigger, standIn);
    }
    SDKHook(standIn, SDKHook_SetTransmit, OnTriggerTransmit);
    int index = g_hStandIns.Push(EntIndexToEntRef(standIn));
    g_hStandIns.Set(index, EntIndexToEntRef(trigger), 1);
}

Action OnTriggerTransmit(int entity, int client) {
    return g_bShowing[client] ? Plugin_Continue : Plugin_Handled;
}
