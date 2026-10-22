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

// Stand-ins are created only while this many edicts stay free...
#define STANDIN_CREATE_MARGIN  288
// ...and all of them are removed once fewer than this many stay free.
#define STANDIN_RELEASE_MARGIN 192
// Room between the two lines for one map's stand-ins (64 on kz_dontjump).
#assert STANDIN_CREATE_MARGIN - STANDIN_RELEASE_MARGIN >= 96

#define LIMIT_NOTE \
    "Some triggers aren't shown: the server is near its entity limit."

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

// Read at their C++ sizes: int, color32, unsigned short, unsigned char.
int g_iEffectsOffset;
int g_iRenderColorOffset;
int g_iSolidFlagsOffset;
int g_iSolidTypeOffset;

bool g_bShowing[MAXPLAYERS + 1];
int g_iViewers;
ArrayList g_hShown;    // trigger reference, saved m_clrRender
ArrayList g_hStandIns; // stand-in reference, trigger reference
int g_iEdicts;         // edicts in use, kept only while active
bool g_bStandInsReleased;
bool g_bLimitNoted;

public void OnPluginStart() {
    g_iEffectsOffset = FindEntityProp("m_fEffects");
    g_iRenderColorOffset = FindEntityProp("m_clrRender");
    g_iSolidFlagsOffset = FindEntityProp("m_usSolidFlags");
    g_iSolidTypeOffset = FindEntityProp("m_nSolidType");
    g_hShown = new ArrayList(2);
    g_hStandIns = new ArrayList(2);
    RegConsoleCmd("sm_showtriggers", Command_ShowTriggers,
                  "Toggles showing trigger brushes for you");
}

int FindEntityProp(const char[] prop) {
    int offset = FindSendPropInfo("CBaseEntity", prop);
    if (offset <= 0)
        SetFailState("Couldn't find CBaseEntity's %s", prop);
    return offset;
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

    bool show = !g_bShowing[client];
    PrintToChat(client, (show ? "Showing trigger brushes."
                              : "Stopped showing trigger brushes."));
    bool noted = g_bLimitNoted;
    SetShowing(client, show);
    // Viewers who turn it on after the note was sent get it too.
    if (show && noted)
        PrintToChat(client, LIMIT_NOTE);
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
    // Player slots are never given to other entities, filled or not.
    g_iEdicts = MaxClients + 1;
    ArrayList triggers = new ArrayList();
    int maxEntities = GetMaxEntities();
    for (int entity = MaxClients + 1; entity < maxEntities; ++entity) {
        if (!IsValidEdict(entity))
            continue;
        ++g_iEdicts;
        if (IsHiddenTrigger(entity))
            triggers.Push(entity);
    }

    // After counting, so the loop never meets a new stand-in.
    for (int i = 0; i < triggers.Length; ++i)
        ShowTrigger(triggers.Get(i));
    delete triggers;
}

void Deactivate() {
    for (int i = 0; i < g_hShown.Length; ++i) {
        int entity = EntRefToEntIndex(g_hShown.Get(i));
        if (entity != INVALID_ENT_REFERENCE)
            Hide(entity, g_hShown.Get(i, 1));
    }
    g_hShown.Clear();
    RemoveStandIns();
    g_bStandInsReleased = false;
    g_bLimitNoted = false;
}

public void OnEntityCreated(int entity, const char[] classname) {
    if (g_iViewers == 0 || entity <= MaxClients || entity >= GetMaxEntities())
        return;

    ++g_iEdicts;
    if (g_hStandIns.Length > 0 &&
        g_iEdicts >= GetMaxEntities() - STANDIN_RELEASE_MARGIN) {
        RemoveStandIns();
        g_bStandInsReleased = true;
        NoteLimit();
    }

    // Solid flags and the model are only set during spawn.
    SDKHook(entity, SDKHook_SpawnPost, OnTriggerSpawnPost);
}

void OnTriggerSpawnPost(int entity) {
    SDKUnhook(entity, SDKHook_SpawnPost, OnTriggerSpawnPost);
    if (g_iViewers > 0 && IsValidEdict(entity) && IsHiddenTrigger(entity))
        ShowTrigger(entity);
}

public void OnEntityDestroyed(int entity) {
    if (g_iViewers == 0 || entity <= MaxClients || entity >= GetMaxEntities())
        return;

    --g_iEdicts;
    // Round restarts keep func_illusionary but rebuild most triggers.
    int index = g_hStandIns.FindValue(EntIndexToEntRef(entity), 1);
    if (index == -1)
        return;

    int standIn = EntRefToEntIndex(g_hStandIns.Get(index));
    if (standIn != INVALID_ENT_REFERENCE)
        RemoveEntity(standIn);
    g_hStandIns.Erase(index);
}

bool IsHiddenTrigger(int entity) {
    if (!(GetEntData(entity, g_iEffectsOffset) & EF_NODRAW))
        return false;

    // Box solids don't collide with their model, so it's the wrong shape.
    int solidType = GetEntData(entity, g_iSolidTypeOffset, 1);
    if (solidType != SOLID_BSP && solidType != SOLID_VPHYSICS)
        return false;

    // Disabled triggers drop FSOLID_TRIGGER but keep CBaseTrigger's fields.
    if (!(GetEntData(entity, g_iSolidFlagsOffset, 2) & FSOLID_TRIGGER) &&
        !HasEntProp(entity, Prop_Data, "m_hTouchingEntities")) {
        return false;
    }

    char model[2];
    GetEntPropString(entity, Prop_Data, "m_ModelName", model, sizeof(model));
    return model[0] == '*';
}

void ShowTrigger(int entity) {
    // Filtering a trigger clients already get would break it for others.
    if (GetEdictFlags(entity) & FL_EDICT_DONTSEND)
        Show(entity);
    else
        AddStandIn(entity);
}

void Show(int entity) {
    SetEntData(entity, g_iEffectsOffset,
               GetEntData(entity, g_iEffectsOffset) & ~EF_NODRAW, 4, true);
    // A raw m_fEffects write skips the recompute RemoveEffects would do.
    SetEdictFlags(entity, ((GetEdictFlags(entity) & ~TRANSMIT_BITS) |
                           FL_EDICT_PVSCHECK |
                           FL_EDICT_DIRTY_PVS_INFORMATION));
    int color = GetEntData(entity, g_iRenderColorOffset);
    SetEntData(entity, g_iRenderColorOffset, color & ALPHA_MASK, 4, true);
    SDKHook(entity, SDKHook_SetTransmit, OnTriggerTransmit);
    int index = g_hShown.Push(EntIndexToEntRef(entity));
    g_hShown.Set(index, color, 1);
}

void Hide(int entity, int color) {
    SDKUnhook(entity, SDKHook_SetTransmit, OnTriggerTransmit);
    SetEntData(entity, g_iRenderColorOffset, color, 4, true);
    // Shown triggers had both flags; the engine keeps a parent networked.
    SetEntData(entity, g_iEffectsOffset,
               GetEntData(entity, g_iEffectsOffset) | EF_NODRAW, 4, true);
    int transmit = GetEntPropEnt(entity, Prop_Data, "m_hMoveChild") == -1
                       ? FL_EDICT_DONTSEND
                       : FL_EDICT_PVSCHECK;
    SetEdictFlags(entity, (GetEdictFlags(entity) & ~TRANSMIT_BITS) | transmit);
}

void AddStandIn(int trigger) {
    if (g_bStandInsReleased ||
        g_iEdicts + 1 > GetMaxEntities() - STANDIN_CREATE_MARGIN) {
        NoteLimit();
        return;
    }

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
    SetEntData(standIn, g_iRenderColorOffset,
               GetEntData(standIn, g_iRenderColorOffset) & ALPHA_MASK, 4,
               true);
    // A child keeps its parent networked, harmless since this one already is.
    if (GetEntPropEnt(trigger, Prop_Data, "m_hMoveParent") != -1) {
        SetVariantString("!activator");
        AcceptEntityInput(standIn, "SetParent", trigger, standIn);
    }
    SDKHook(standIn, SDKHook_SetTransmit, OnTriggerTransmit);
    int index = g_hStandIns.Push(EntIndexToEntRef(standIn));
    g_hStandIns.Set(index, EntIndexToEntRef(trigger), 1);
}

void RemoveStandIns() {
    for (int i = 0; i < g_hStandIns.Length; ++i) {
        int standIn = EntRefToEntIndex(g_hStandIns.Get(i));
        if (standIn != INVALID_ENT_REFERENCE)
            RemoveEntity(standIn);
    }
    g_hStandIns.Clear();
}

void NoteLimit() {
    if (g_bLimitNoted)
        return;

    g_bLimitNoted = true;
    for (int client = 1; client <= MaxClients; ++client) {
        if (g_bShowing[client])
            PrintToChat(client, LIMIT_NOTE);
    }
}

Action OnTriggerTransmit(int entity, int client) {
    return g_bShowing[client] ? Plugin_Continue : Plugin_Handled;
}
