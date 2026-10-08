package com.sankalpa.application;

public enum PracticeContract {
    SINGLE_VOW_V1, LINKED_V1;
    public void requireLinked() {
        if (this != LINKED_V1) throw new PracticeException("LINKED_SANKALPA_UPGRADE_REQUIRED", "Update the client to use linked vows");
    }
}
