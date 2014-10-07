/*
    Copyright (C) 2014-2015  Juan Jose Alvarez Martinez <juanjo@juanjoalvarez.net>

    This file is part of Wodri. Wodri is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License version 3 as published by the
    Free Software Foundation.

    This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
    without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
    See the GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License along with this
    program. If not, see <http://www.gnu.org/licenses/>.
*/
module webbackend.apiconversationsummary;

import common.utils;
import db.conversation;
import db.email;
import retriever.incomingemail: EMAIL_REGEX;
import std.algorithm;
import std.array;
import std.conv;
import std.regex;
import std.stdio;
import std.string;

auto NAME_CLEAN_REGEX = ctRegex!(r"[<>]", "g");


final class ApiConversationSummary
{
    string         id;
    ulong          numMessages;
    string         lastDate;
    string         subject;
    string[]       shortAuthors;
    string[]       attachFileNames;
    const string[] tags;

    this (in Conversation conv, in bool withDeleted = false)
    {
        this.id     = conv.id;
        this.lastDate = conv.lastDate;
        this.tags     = conv.tagsArray;
        this.subject  = conv.cleanSubject;

        foreach(link; conv.links)
        {
            if (!withDeleted && link.deleted)
                continue;

            this.numMessages += 1;
            if (link.emailDbId.length)
            {
                const emailSummary = Email.getSummary(link.emailDbId);
                this.shortAuthors ~= match(emailSummary.from, EMAIL_REGEX)
                                    .pre.translate(['<': ' ', '>': ' ']).strip();

                if (emailSummary.attachFileNames.length)
                {
                    auto joinedAttachs = this.attachFileNames ~ emailSummary.attachFileNames;
                    sort(joinedAttachs);
                    this.attachFileNames = uniq(joinedAttachs).array;
                }
            }
        }
    }
}
