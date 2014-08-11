module db.utils;

T[] removeDups(T)(const T[] input)
{
    bool[T] dict;

    foreach(T item; input)
    {
        if (item !in dict)
            dict[item] = true;
    }
    return dict.keys;
}
