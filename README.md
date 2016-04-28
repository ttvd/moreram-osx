# moreram-osx

## Notes

* This is a malloc replacement for Mac OS X which will attempt to use memory available through Metal API. The Metal allocations
are only triggered when regular malloc/realloc/calloc/free calls fail. Otherwise it will use default calls.
* This is inspired by [moreram](https://github.com/graphitemaster/moreram)
* This is perhaps a joke.
* This can potentially waste memory (due to shadowing).
* This is still work in progress.

## License

* Copyright Mykola Konyk, 2016
* Distributed under the [MS-RL License.](http://opensource.org/licenses/MS-RL)
* **To further explain the license:**
    * **You cannot re-license any files in this project.**
    * **That is, they must remain under the [MS-RL license.](http://opensource.org/licenses/MS-RL)**
    * **Any other files you add to this project can be under any license you want.**
    * **You cannot use any of this code in a GPL project.**
    * Otherwise you are free to do pretty much anything you want with this code.
