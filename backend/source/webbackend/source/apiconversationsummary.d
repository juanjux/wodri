module webbackend.apiconversationsummary;

import std.regex;
import std.algorithm;
import std.stdio;
import std.conv;
import std.string;
import std.array;
import retriever.db;
import retriever.conversation;
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

        foreach(link; conv.links)
        {
            if (link.emailDbId.length)
            {
                auto emailSummary = getEmailSummary(link.emailDbId);
                auto filteredSubject = replaceAll!(x => "")(emailSummary.subject,
                                                           SUBJECT_CLEAN_REGEX);
                if (!this.subject.length && filteredSubject.length)
                    this.subject = filteredSubject;

                this.shortAuthors ~= match(emailSummary.from, EMAIL_REGEX)
                                    .pre.translate(['<': ' ', '>': ' ']).strip();

                if (emailSummary.attachFileNames.length)
                    this.attachFileNames = uniq(this.attachFileNames ~
                                                emailSummary.attachFileNames).array();
            }
        }
    }
}
