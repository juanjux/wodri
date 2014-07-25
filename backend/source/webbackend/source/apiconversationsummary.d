module webbackend.apiconversationsummary;

import std.regex;
import std.algorithm;
import std.stdio;
import std.conv;
import std.string;
import std.array;
import db.mongo;
import db.conversation;
import db.email;
import retriever.incomingemail: EMAIL_REGEX;

auto SUBJECT_CLEAN_REGEX = ctRegex!(r"([\[\(] *)?(RE?) *([-:;)\]][ :;\])-]*|$)|\]+ *$", "gi");
auto NAME_CLEAN_REGEX = ctRegex!(r"[<>]", "g");


struct ApiConversationSummary
{
    string         dbId;
    ulong          numMessages;
    string         lastDate;
    string         subject;
    string[]       shortAuthors;
    string[]       attachFileNames;
    const string[] tags;

    this (const Conversation conv)
    {
        this.dbId = conv.dbId;
        this.numMessages = conv.links.length;
        this.lastDate = conv.lastDate;
        this.tags = conv.tags;
        this.subject = conv.cleanSubject;

        foreach(link; conv.links)
        {
            if (link.emailDbId.length)
            {
                auto emailSummary  = Email.getSummary(link.emailDbId);
                this.shortAuthors ~= match(emailSummary.from, EMAIL_REGEX)
                                    .pre.translate(['<': ' ', '>': ' ']).strip();

                if (emailSummary.attachFileNames.length)
                    this.attachFileNames = uniq(this.attachFileNames ~
                                                emailSummary.attachFileNames).array();
            }
        }
    }
}
