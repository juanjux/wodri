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
module db.dbinterface.driverconversationinterface;

import db.email;
import db.conversation: Conversation;
import std.typecons;

struct EmailAndConvIds
{
    string emailId;
    string convId;
}


interface DriverConversationInterface
{
    const(EmailAndConvIds[]) searchEmails(
            in string[] needles,
            in string userId,
            in string dateStart = "",
            in string dateEnd = ""
    );

    Conversation get(in string id);

    Conversation getByReferences(in string userId,
                                 in string[] references,
                                 in Flag!"WithDeleted" withDeleted = No.WithDeleted);

    Conversation getByEmailId(in string emailId,
                              in Flag!"WithDeleted" withDeleted = No.WithDeleted);

    Conversation[] getByTag(in string tagName,
                            in string userId,
                            in uint limit=0,
                            in uint page=0,
                            in Flag!"WithDeleted" withDeleted = No.WithDeleted);

    void store(Conversation conv);

    void remove(Conversation conv);

    /** Could create a new conversation **/
    Conversation addEmail(in Email email, in string[] tagsToAdd, in string[] tagsToRemove);

    bool isOwnedBy(in string convId, in string userName);
}
