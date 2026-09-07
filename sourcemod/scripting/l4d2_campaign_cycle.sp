/**
 * l4d2_campaign_cycle.sp — after a finale, move the group to the next campaign.
 *
 * WHY NOT mapcycle.txt, WHICH IS WHAT THE ENGINE APPEARS TO OFFER. The image
 * ships one, and its four entries were maps from the first game under their
 * pre-port names, so it pointed at nothing and the server restarted the same
 * campaign after every finale. Fixing those names was necessary and not
 * sufficient: L4D2 has no nextlevel, sv_nextlevel, mapcyclefile or
 * map_transition command — all four answer "Unknown command" — so there is no
 * way to see whether the engine reads that file in co-op at all, and plenty of
 * community plugins exist for exactly this job, which is its own evidence.
 *
 * A rotation nobody can verify is not a rotation. This does it explicitly, on
 * an event the game definitely fires, and exposes sm_cyclenext so the behaviour
 * can be tested without playing four hours to reach a finale.
 */
#include <sourcemod>

#define DELAY 20.0   // let the escape scene and the score screen finish

char g_sCycle[14][] = {
    "c9m1_alleys",        // Crash Course      — first-game survivors
    "c10m1_caves",        // Death Toll
    "c11m1_greenhouse",   // Dead Air
    "c12m1_hilltop",      // Blood Harvest
    "c7m1_docks",         // The Sacrifice
    "c14m1_junkyard",     // The Last Stand
    "c1m1_hotel",         // Dead Center       — second-game survivors
    "c6m1_riverbank",     // The Passing
    "c2m1_highway",       // Dark Carnival
    "c3m1_plankcountry",  // Swamp Fever
    "c4m1_milltown_a",    // Hard Rain
    "c5m1_waterfront",    // The Parish
    "c13m1_alpinecreek",  // Cold Stream
    "c8m1_apartment"      // No Mercy          — and round again
};

public Plugin myinfo = {
    name = "L4D2 campaign cycle",
    author      = "heyvaldemar",
    description = "Next campaign after each finale, looping forever",
    version = "1.0"
};

public void OnPluginStart() {
    HookEvent("finale_win", Event_FinaleWin, EventHookMode_PostNoCopy);
    RegAdminCmd("sm_cyclenext", Cmd_Next, ADMFLAG_GENERIC,
                "sm_cyclenext — jump to the next campaign now (for testing)");
}

/**
 * Which campaign follows the one we are on.
 *
 * MATCHED ON THE CAMPAIGN PREFIX, not the whole map name. The finale runs on the
 * LAST chapter — c9m2_lots, not c9m1_alleys — so comparing full names would
 * never match and the cycle would silently always start from the beginning.
 */
int NextIndex() {
    char now[64];
    GetCurrentMap(now, sizeof(now));

    // "c9m2_lots" -> "c9"
    int m = FindCharInString(now, 'm');
    if (m < 1) return 0;
    char prefix[8];
    strcopy(prefix, m + 1, now);

    for (int i = 0; i < sizeof(g_sCycle); i++) {
        int em = FindCharInString(g_sCycle[i], 'm');
        char p2[8];
        strcopy(p2, em + 1, g_sCycle[i]);
        if (StrEqual(prefix, p2)) {
            return (i + 1) % sizeof(g_sCycle);
        }
    }
    return 0;
}

public void Event_FinaleWin(Event event, const char[] name, bool dontBroadcast) {
    CreateTimer(DELAY, Timer_Next);
}

public Action Cmd_Next(int client, int args) {
    int i = NextIndex();
    ReplyToCommand(client, "[l4d2] Next campaign: %s", g_sCycle[i]);
    CreateTimer(1.0, Timer_Next);
    return Plugin_Handled;
}

public Action Timer_Next(Handle timer) {
    int i = NextIndex();
    PrintToChatAll("[l4d2] Next campaign: %s", g_sCycle[i]);
    ServerCommand("changelevel %s", g_sCycle[i]);
    return Plugin_Stop;
}
