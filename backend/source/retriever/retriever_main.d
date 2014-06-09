#!/usr/bin/env rdmd

import std.stdio;
import std.file;
import std.path;
import incomingemail;

// XXX Probar con inputs jodidos a ver que excepcion da
// XXX Objeto config (mirar Scramjets)

struct Config
{
    string rawMailStore;
    string attachmentStore;
    string[] receiveDomains;
}

Config getConfig()
// FIXME XXX: hacer objeto config
{
    string mainDir = "/home/juanjux/webmail";
    Config config;
    config.receiveDomains ~= "mooo.com";
    config.rawMailStore = buildPath(mainDir, "backend", "test", "rawmails");
    config.attachmentStore = buildPath(mainDir, "backend", "test", "attachments");
    return config;
}

int main()
{
    auto f = File("/home/juanjux/webmail/backend/source/retriever/log.txt", "a");
    auto config = getConfig();
    f.writeln("XXX 1");
    auto mail = new IncomingEmail(config.rawMailStore, config.attachmentStore);
    f.writeln("XXX 2");
    mail.loadFromFile(std.stdio.stdin);
    f.writeln("XXX 3");
    if ("From:" in mail.headers) writeln("From: ", mail.headers["From:"]);

    if (mail.isValid)
    {
        // XXX
        // 1. Comprobar si en el To: va a un dominio admitido y a un usuario valido
        // 2. Comprobar si tiene la marca de spam y aniadirle el tag
        // 3. Ejecutar la comprobacion de reglas
        f.writeln("XXX 4 isValid");
        return 0;
    }
    f.writeln("XXX 5 is not valid");
    return 1;
}
