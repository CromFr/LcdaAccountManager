import {Injectable} from "angular2/core";
import {Http, Response} from "angular2/http";
import {Observable}     from "rxjs/Observable";

import {Character}      from "./charlist.component";

@Injectable()
export class CharListService {
    constructor (private http: Http) {}

    getList() {
        return this.http.get("/Crom 29/char/list")
                            .map(res => <Character[][]> res.json())
                            .catch(this.handleError);
    }


    private handleError (error: Response) {
        // in a real world app, we may send the error to some remote logging infrastructure
        // instead of just logging it to the console
        console.error(error);
        return Observable.throw(error.json().error || "Server error");
      }
}