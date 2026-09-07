/**
 * l4d2_character_select.sp — let a player choose which survivor they are.
 *
 * WHY THIS EXISTS AT ALL. Left 4 Dead 2 assigns survivors on join and offers no
 * way to change: the roster is fixed by the campaign — Bill, Zoey, Francis and
 * Louis on the first game's maps, Coach, Nick, Ellis and Rochelle on the
 * second's — and which of the four you get is the server's choice, not yours.
 * The only vanilla route is sb_takecontrol, which needs sv_cheats 1, and that
 * turns cheats on for everyone on the server to solve one person's preference.
 *
 * WRITTEN RATHER THAN DOWNLOADED. A forum attachment would have been faster and
 * is a binary of unknown provenance running inside the game server; this is
 * fifty lines compiled here with the compiler SourceMod ships.
 *
 * TWO PROPERTIES, NOT ONE. Setting m_survivorCharacter alone changes who the
 * game thinks you are — voice lines, portrait — while you keep walking around
 * in the old body. Setting only the model does the reverse. Both together is
 * what actually swaps the character.
 */
#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.0"

// index -> model. The order is the game's own m_survivorCharacter numbering:
// the four from the second game first, then the four from the first.
char g_sModel[8][] = {
    "models/survivors/survivor_gambler.mdl",    // 0 Nick
    "models/survivors/survivor_producer.mdl",   // 1 Rochelle
    "models/survivors/survivor_coach.mdl",      // 2 Coach
    "models/survivors/survivor_mechanic.mdl",   // 3 Ellis
    "models/survivors/survivor_namvet.mdl",     // 4 Bill
    "models/survivors/survivor_teenangst.mdl",  // 5 Zoey
    "models/survivors/survivor_biker.mdl",      // 6 Francis
    "models/survivors/survivor_manager.mdl"     // 7 Louis
};
char g_sName[8][] = {
    "nick", "rochelle", "coach", "ellis",
    "bill", "zoey", "francis", "louis"
};

public Plugin myinfo = {
    name = "L4D2 character select",
    author      = "heyvaldemar",
    description = "Choose your survivor with !char",
    version = PLUGIN_VERSION
};

public void OnPluginStart() {
    // FindTarget REPORTS ITS FAILURES THROUGH TRANSLATED PHRASES, and without
    // this it throws "Language phrase 'No matching client' not found" instead
    // of saying no such player. The refusal path is the one somebody hits when
    // they mistype a name, so it is the last place that should itself fail.
    LoadTranslations("common.phrases");

    RegConsoleCmd("sm_char", Cmd_Char, "!char <name> — become that survivor");
    RegConsoleCmd("sm_chars", Cmd_List, "!chars — list the names");
    // FOR RCON, WHICH IS HOW EVERYTHING ELSE ON THIS HOST IS DRIVEN. sm_char
    // acts on whoever typed it, so over rcon there is nobody to act on and it
    // can only refuse. This one names its target, so the same ssh one-liner
    // pattern as every other command in the runbook works here too.
    RegAdminCmd("sm_setchar", Cmd_SetChar, ADMFLAG_GENERIC,
                "sm_setchar <player> <name> — change someone else's survivor");
}

public Action Cmd_SetChar(int client, int args) {
    if (args < 2) {
        ReplyToCommand(client, "[l4d2] Usage: sm_setchar <player> <name>");
        return Plugin_Handled;
    }
    char who[64], arg[32];
    GetCmdArg(1, who, sizeof(who));
    GetCmdArg(2, arg, sizeof(arg));
    String_ToLower(arg, sizeof(arg));

    // BOTS ALLOWED AS TARGETS. Not for convenience — it is the only way to test
    // this command without a person in the game, and the last version was handed
    // over untested and crashed a live session twice. Changing Francis is also
    // occasionally useful in its own right.
    int target = FindTarget(client, who, false, false);
    if (target < 1) return Plugin_Handled;   // FindTarget already explained why

    if (GetClientTeam(target) != 2 || !IsPlayerAlive(target)) {
        ReplyToCommand(client, "[l4d2] %N is not a living survivor.", target);
        return Plugin_Handled;
    }
    for (int i = 0; i < 8; i++) {
        if (StrEqual(arg, g_sName[i])) {
            if (!IsModelPrecached(g_sModel[i])) {
                ReplyToCommand(client, "[l4d2] %s is not available on this map.", g_sName[i]);
                return Plugin_Handled;
            }
            SetEntProp(target, Prop_Send, "m_survivorCharacter", i);
            SetEntityModel(target, g_sModel[i]);
            ReplyToCommand(client, "[l4d2] %N is now %s.", target, g_sName[i]);
            PrintToChat(target, "[l4d2] You are now %s.", g_sName[i]);
            return Plugin_Handled;
        }
    }
    ReplyToCommand(client, "[l4d2] No survivor called '%s'.", arg);
    return Plugin_Handled;
}

/**
 * PRECACHE, OR THE SERVER DIES. SetEntityModel with a model the current map has
 * not registered crashes srcds outright — not an error, not a refusal, the
 * process is gone and everybody is disconnected. It cost two crashes and a live
 * co-op session on 2026-08-21: three players, mid-campaign, twice within four
 * minutes, each one about thirty seconds after somebody typed !char.
 *
 * The eight survivor models are not all resident on every campaign — the first
 * game's maps carry Bill, Zoey, Francis and Louis, the second's carry the other
 * four — so a command that offers all eight has to put all eight into the map's
 * string table itself, at map load, before anyone can ask for one.
 */
public void OnMapStart() {
    for (int i = 0; i < 8; i++) {
        PrecacheModel(g_sModel[i], true);
    }
}

public Action Cmd_List(int client, int args) {
    ReplyToCommand(client, "[l4d2] nick rochelle coach ellis bill zoey francis louis");
    return Plugin_Handled;
}

public Action Cmd_Char(int client, int args) {
    if (client < 1 || !IsClientInGame(client)) return Plugin_Handled;

    // Survivor team only. A dead or spectating player has no model to swap, and
    // silently doing nothing is how a command earns the reputation of "broken".
    if (GetClientTeam(client) != 2 || !IsPlayerAlive(client)) {
        ReplyToCommand(client, "[l4d2] Only while alive as a survivor.");
        return Plugin_Handled;
    }
    if (args < 1) {
        ReplyToCommand(client, "[l4d2] Usage: !char <name>. !chars lists them.");
        return Plugin_Handled;
    }

    char arg[32];
    GetCmdArg(1, arg, sizeof(arg));
    String_ToLower(arg, sizeof(arg));

    for (int i = 0; i < 8; i++) {
        if (StrEqual(arg, g_sName[i])) {
            // BELT AND BRACES. Precaching at map start should make this
            // impossible, but the failure mode is a crash that takes the whole
            // session with it, so the model is checked rather than trusted.
            if (!IsModelPrecached(g_sModel[i])) {
                ReplyToCommand(client, "[l4d2] %s is not available on this map.", g_sName[i]);
                return Plugin_Handled;
            }
            SetEntProp(client, Prop_Send, "m_survivorCharacter", i);
            SetEntityModel(client, g_sModel[i]);
            ReplyToCommand(client, "[l4d2] You are now %s.", g_sName[i]);
            return Plugin_Handled;
        }
    }
    ReplyToCommand(client, "[l4d2] No survivor called '%s'. Try !chars.", arg);
    return Plugin_Handled;
}

void String_ToLower(char[] s, int size) {
    for (int i = 0; i < size && s[i]; i++) s[i] = CharToLower(s[i]);
}
