import {Component} from "angular2/core";

import {CharListComponent} from "./charlist.component";

@Component({
    selector:    "app",
    directives:  [CharListComponent],
    templateUrl: "app/app.component.html",
})
export class AppComponent {
    public isLoggedIn: bool = false;
    public account: string;
}