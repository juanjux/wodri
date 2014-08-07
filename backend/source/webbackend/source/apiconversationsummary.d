module webbackend.apiconversationsummary;

import db.conversation;
import db.email;
import db.mongo;
import retriever.incomingemail: EMAIL_REGEX;
import std.algorithm;
import std.array;
import std.conv;
import std.regex;
import std.stdio;
import std.string;

auto SUBJECT_CLEAN_REGEX = ctRegex!(
        r"([\[\(] *)?(RE?) *([-:;)\]][ :;\])-]*|$)|\]+ *$", 
        "gi"
);
auto NAME_CLEAN_REGEX = ctRegex!(r"[<>]", "g");


final class ApiConversationSummary
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
        this.lastDate = conv.lastDate;
        this.tags = conv.tagsArray;
        this.subject = conv.cleanSubject;

        foreach(link; conv.links)
        {
            if (link.deleted)
                continue;

            this.numMessages += 1;
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
