#!/usr/bin/env rdmd

import std.stdio;
import std.regex;
import std.conv;
import std.algorithm;
import std.file;
import std.array;
import std.string;
import std.path;

import incomingemail;
import config;
import userrule;

// ===TODO===
// XXX Sistema de log (al log del sistema y MongoDB)
// XXX loguear emails rechazados
// XXX Clase de config y cargador de config desde MongoDB
// XXX Cargador de userRules desde MongoDB;
// XXX email.setTag y email.removeTag
// XXX unittest en userrule.d con algunos emails de prueba sencillos fijos
// XXX Almacenador en MongoDB
// XXX Indexacion


bool hasValidDestination(IncomingEmail email, string[][string] validDestinations)
// Checks if there is at least one valid destination (user managed by us) 
{
    string[] addresses;

    foreach(string header; ["To", "Cc", "Bcc", "Delivered-To"])
        addresses ~= email.extractAddressesFromHeader(header);

    string user, domain;
    foreach(string addr; addresses)
    {
        auto addrtokens = addr.split("@");

        if (addrtokens.length != 2)
            continue;

        user   = addrtokens[0];
        domain = toLower(addrtokens[1]);

        if (domain in validDestinations && find(validDestinations[domain], user).length)
            return true;
    }
    return false;
}


int main()
{
    auto f = File("/home/juanjux/webmail/backend/source/retriever/log.txt", "a");
    auto config = getConfig();
    auto mail = new IncomingEmail(config.rawMailStore, config.attachmentStore);
    mail.loadFromFile(std.stdio.stdin);

    if (mail.isValid && hasValidDestination(mail, config.validDestinations))
    {
        if ("X-Spam-SetSpamTag" in mail.headers)
            mail.tags["spam"] = true;
    }
    else
    {
        // XXX loguear el mensaje rechazado
    }

    return 0; // return != 0 == Postfix bound. Avoid
}
