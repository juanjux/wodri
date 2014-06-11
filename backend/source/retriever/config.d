import std.path;

struct Config
{
    string rawMailStore;
    string attachmentStore;
    string[][string] validDestinations;
}

Config getConfig()
{
    string mainDir          = "/home/juanjux/webmail";
    Config config;
    config.validDestinations["mooo.com"]       = ["juanjux", "postmaster"];
    config.validDestinations["fakedomain.com"] = ["fakeUser", "*"];
    config.rawMailStore                        = buildPath(mainDir, "backend", "test", "rawmails");
    config.attachmentStore                     = buildPath(mainDir, "backend", "test", "attachments");
    return config;
}

