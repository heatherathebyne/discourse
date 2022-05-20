import Controller from "@ember/controller";
import ModalFunctionality from "discourse/mixins/modal-functionality";
import { action } from "@ember/object";
import { notEmpty } from "@ember/object/computed";
import { inject as service } from "@ember/service";
import { popupAjaxError } from "discourse/lib/ajax-error";
import bootbox from "bootbox";

export default Controller.extend(ModalFunctionality, {
  userStatusService: service("user-status"),

  description: "",
  statusIsSet: notEmpty("description"),
  showDeleteButton: false,

  onShow() {
    if (this.currentUser.status?.description) {
      this.setProperties({
        description: this.currentUser.status?.description,
        showDeleteButton: !!this.currentUser.status?.description,
      });
    }
  },

  @action
  delete() {
    this.userStatusService
      .clear()
      .then(() => {
        this.set("description", "");
        this.send("closeModal");
      })
      .catch((e) => this._handleError(e));
  },

  @action
  saveAndClose() {
    if (this.description) {
      const status = { description: this.description };
      this.userStatusService
        .set(status)
        .then(() => {
          this.send("closeModal");
        })
        .catch((e) => this._handleError(e));
    }
  },

  _handleError(e) {
    if (typeof e === "string") {
      bootbox.alert(e);
    } else {
      popupAjaxError(e);
    }
  },
});
