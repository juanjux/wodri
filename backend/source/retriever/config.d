module retriever.config;

import std.path;

struct Config
{
    string mainDir;
    string rawMailStore;
    string attachmentStore;
    string[][string] validDestinations;
}

// XXX validDestination:
// 1. config.domain.defaultUser != empty => valid
// else: db.users.find({addresses: {$in: [DIRECCION1, DIRECCION2, etc]}})
// (solo para cada direccion cuyo dominio sea uno de los nuestros)
Config getConfig()
{
    string mainDir          = "/home/juanjux/webmail";
    Config config;
    config.validDestinations["mooo.com"]       = ["juanjux", "postmaster"];
    config.validDestinations["fakedomain.com"] = ["fakeUser", "*"];
    config.mainDir = mainDir;
    config.rawMailStore                        = buildPath(mainDir, "backend", "test", "rawmails");
    config.attachmentStore                     = buildPath(mainDir, "backend", "test", "attachments");
    return config;
}

